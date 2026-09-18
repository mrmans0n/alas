import Foundation
import Observation

enum WorkspaceLoadState: Equatable {
    case notLoaded
    case loaded(WorkspaceStateFile)
    case unreadable(WorkspaceRecoveryState)
}

/// Owns the Workspace preview boundary. When disabled it deliberately does
/// not touch `workspaces.json`; this lets an older-style Alas session keep its
/// Workspace data dormant without reconciling or rewriting it.
@Observable
@MainActor
final class WorkspacesManager {
    private let bridge: WorkspaceSpacePersistenceBridge
    private let observer: any WorkspaceCheckoutObserving
    private(set) var loadState: WorkspaceLoadState = .notLoaded
    private(set) var dormantCheckouts: [WorkspaceCheckout] = []
    private(set) var checkoutReconciliations: [UUID: WorkspaceCheckoutReconciliation] = [:]

    var canMutate: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    var recoveryState: WorkspaceRecoveryState? {
        guard case .unreadable(let recovery) = loadState else { return nil }
        return recovery
    }

    var workspaces: [Workspace] {
        guard case let .loaded(state) = loadState else { return [] }
        return state.workspaces
    }

    var checkouts: [WorkspaceCheckout] {
        guard case let .loaded(state) = loadState else { return [] }
        return state.checkouts.map(presentedCheckout)
    }

    var ownershipCheckouts: [WorkspaceCheckout] {
        if case .loaded = loadState {
            return checkouts
        }
        return dormantCheckouts
    }

    /// Current persisted/reconciled checkout snapshot for runtime session
    /// attachment. Returns nil while Workspace storage is unavailable rather
    /// than fabricating a focus-derived replacement.
    func checkout(id: UUID) -> WorkspaceCheckout? {
        guard case let .loaded(state) = loadState else { return nil }
        return state.checkouts
            .first(where: { $0.id == id })
            .map(presentedCheckout)
    }

    init(bridge: WorkspaceSpacePersistenceBridge = WorkspaceSpacePersistenceBridge(), observer: any WorkspaceCheckoutObserving = WorkspaceCheckoutObserver()) {
        self.bridge = bridge
        self.observer = observer
    }

    /// Enables or disables the preview. Disabling is intentionally a pure
    /// in-memory gate: it neither deletes nor rewrites Workspace storage.
    func setEnabled(_ enabled: Bool, spacesFile: SpacesFile) async -> SpacesFile? {
        guard enabled else {
            if case let .loaded(state) = loadState {
                dormantCheckouts = state.checkouts.map(presentedCheckout)
            }
            loadState = .notLoaded
            checkoutReconciliations = [:]
            return nil
        }
        dormantCheckouts = []

        switch await bridge.load() {
        case .missing:
            let state = WorkspaceStateFile()
            loadState = .loaded(state)
            return nil
        case .unreadable(let recovery):
            loadState = .unreadable(recovery)
            return nil
        case .loaded(let state):
            loadState = .loaded(state)
            checkoutReconciliations = await reconcileCheckouts(in: state)
            // Enabling is strictly observational. Future explicit Workspace
            // operations own persistence; the preview gate must never rewrite
            // an otherwise valid state merely because the app launched.
            let result = WorkspaceSpaceMigration.reupgrade(
                spacesFile: spacesFile,
                savedLayouts: state.spaceLayouts
            )
            return result.spaces == spacesFile.spaces ? nil : SpacesFile(
                activeSpaceId: spacesFile.activeSpaceId,
                spaces: result.spaces,
                showSingleSpaceAffordance: spacesFile.showSingleSpaceAffordance
            )
        }
    }

    /// Creation progress only needs to inspect the checkout being created.
    /// Keep observations for unrelated, unchanged snapshots without contacting their hosts.
    func refreshCheckoutSnapshots(reconciling checkoutID: UUID? = nil) async {
        guard case .loaded(let previous) = loadState else { return }
        switch await bridge.load() {
        case .loaded(let state):
            guard canMutate else { return }
            loadState = .loaded(state)
            if let checkoutID {
                let previousByID = Dictionary(uniqueKeysWithValues: previous.checkouts.map { ($0.id, $0) })
                let unchangedIDs = Set(state.checkouts.filter { previousByID[$0.id] == $0 }.map(\.id))
                checkoutReconciliations = checkoutReconciliations.filter { unchangedIDs.contains($0.key) }
                let report = try? await bridge.reconcileCheckout(id: checkoutID, observer: observer)
                guard canMutate else { return }
                checkoutReconciliations[checkoutID] = report
            } else {
                let reports = await reconcileCheckouts(in: state)
                guard canMutate else { return }
                checkoutReconciliations = reports
            }
        case .unreadable(let recovery):
            loadState = .unreadable(recovery)
            checkoutReconciliations = [:]
        case .missing:
            loadState = .loaded(.init())
            checkoutReconciliations = [:]
        }
    }

    private func reconcileCheckouts(in state: WorkspaceStateFile) async -> [UUID: WorkspaceCheckoutReconciliation] {
        var reports: [UUID: WorkspaceCheckoutReconciliation] = [:]
        for checkout in state.checkouts {
            if let report = try? await bridge.reconcileCheckout(id: checkout.id, observer: observer) {
                reports[checkout.id] = report
            }
        }
        return reports
    }

    private func presentedCheckout(_ checkout: WorkspaceCheckout) -> WorkspaceCheckout {
        guard let report = checkoutReconciliations[checkout.id] else { return checkout }
        var copy = checkout
        copy.members = checkout.members.map { member in
            guard member.availability != .explicitlyDeleted else { return member }
            guard let observation = report.observations[member.id] else { return member }
            var presented = member
            switch observation {
            case .exactLineage:
                presented.availability = .available
            case .missing:
                presented.availability = .missing
            case .identityConflict:
                presented.availability = .identityConflict
            case .unavailable:
                presented.availability = .unavailable
            }
            return presented
        }
        return copy
    }

    /// Checkpoints typed Space layout only while the preview has an editable,
    /// successfully loaded Workspace state.
    func checkpointSpaceLayouts(afterWriting spacesFile: SpacesFile) async throws {
        guard canMutate else { return }
        try await bridge.checkpointAfterSpacesWrite(spacesFile)
    }
}
