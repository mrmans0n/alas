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
    private(set) var loadState: WorkspaceLoadState = .notLoaded

    var canMutate: Bool {
        if case .loaded = loadState { return true }
        return false
    }

    var recoveryState: WorkspaceRecoveryState? {
        guard case .unreadable(let recovery) = loadState else { return nil }
        return recovery
    }

    init(bridge: WorkspaceSpacePersistenceBridge = WorkspaceSpacePersistenceBridge()) {
        self.bridge = bridge
    }

    /// Enables or disables the preview. Disabling is intentionally a pure
    /// in-memory gate: it neither deletes nor rewrites Workspace storage.
    func setEnabled(_ enabled: Bool, spacesFile: SpacesFile) async -> SpacesFile? {
        guard enabled else {
            loadState = .notLoaded
            return nil
        }

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

    /// Checkpoints typed Space layout only while the preview has an editable,
    /// successfully loaded Workspace state.
    func checkpointSpaceLayouts(afterWriting spacesFile: SpacesFile) async throws {
        guard canMutate else { return }
        try await bridge.checkpointAfterSpacesWrite(spacesFile)
    }
}
