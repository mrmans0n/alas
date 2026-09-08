import Foundation

/// The smallest mutation surface required to execute a frozen checkout plan.
/// It intentionally does not expose the general Git or Worktree services.
protocol WorkspaceGitOperating: Sendable {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws
    func preparedBranchMatchesFrozenBase(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String?
    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String?
    func frozenWorktreeIsMissing(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool
}

extension WorkspaceGitOperating {
    func preparedBranchMatchesFrozenBase(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool { false }
    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
    func frozenWorktreeIsMissing(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool {
        try await existingCreatedWorktreeLineage(operation) == nil
    }
}

protocol WorkspaceScriptRunning: Sendable {
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws
}

/// Checkout-owned processes are deliberately separate from repository focus.
/// The concrete owner-aware implementation lands with shared Terminal/ACP
/// storage; this seam already makes archive a durable lifecycle operation.
protocol WorkspaceCheckoutSessionStopping: Sendable {
    func stopSessions(for checkoutID: UUID) async throws
}

/// Bridges checkout lifecycle orchestration to AppState without letting the
/// coordinator learn about focus or SwiftUI. Callers intentionally provide
/// the complete snapshot so the location-qualified owner is preserved.
struct WorkspaceCheckoutSessionStopper: WorkspaceCheckoutSessionStopping {
    let store: WorkspaceStore
    let stop: @MainActor @Sendable (WorkspaceCheckout) async throws -> Void

    func stopSessions(for checkoutID: UUID) async throws {
        guard let checkout = await store.checkout(id: checkoutID) else { return }
        try await stop(checkout)
    }
}

protocol WorkspaceCheckoutLifecycleOperating: Sendable {
    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight
    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation
    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation
    /// Clears stale Git worktree metadata for a missing frozen destination.
    func clearStaleRegistration(_ plan: WorkspaceCheckoutCleanupPlan) async throws
    /// Restores any interrupted stale metadata tombstone without clearing a registration.
    func recoverStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws
    /// Removes tombstoned stale metadata after replacement worktree creation succeeds.
    func finalizeStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws
    /// Explicit user deletion may intentionally unlock and prune a missing worktree.
    func clearStaleRegistrationForExplicitDeletion(_ plan: WorkspaceCheckoutCleanupPlan) async throws
    /// Removes only the worktree. Branch deletion is intentionally disabled.
    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool, forceTwice: Bool) async throws
    /// Removes checkout-owned root artifacts after all member worktrees are gone.
    func removeCheckoutRootArtifacts(for checkout: WorkspaceCheckout) async throws
    /// Attempts a normal merged-only branch deletion for an attempt-created
    /// branch. `false` means it was retained (for example, unmerged).
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool
}

extension WorkspaceCheckoutLifecycleOperating {
    func clearStaleRegistration(_ plan: WorkspaceCheckoutCleanupPlan) async throws {}
    func recoverStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws {}
    func finalizeStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws {}
    func clearStaleRegistrationForExplicitDeletion(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        try await clearStaleRegistration(plan)
    }
}

struct NoopWorkspaceCheckoutSessionStopper: WorkspaceCheckoutSessionStopping {
    func stopSessions(for checkoutID: UUID) async throws {}
}

struct WorkspaceFrozenWorktreeOperation: Sendable {
    var checkoutID: UUID
    var checkoutMemberID: UUID
    var projectID: String
    var executionLocation: ExecutionLocation
    var sourceRepositoryPath: String
    var destinationPath: String
    var branch: String
    var baseCommit: String
    var branchIntent: FrozenBranchIntent
    var expectedLineageID: String?
    var canRecordMissingLineage: Bool = false
}

enum FrozenBranchIntent: Equatable, Sendable {
    case create(atCommit: String)
    case reuse(atCommit: String)

    init(_ intent: WorkspaceBranchIntent, baseCommit: String) {
        switch intent {
        case .create(let commit): self = .create(atCommit: commit)
        case .reuse: self = .reuse(atCommit: baseCommit)
        }
    }

    var commit: String {
        switch self {
        case .create(let atCommit), .reuse(let atCommit): atCommit
        }
    }
}

struct WorkspaceCheckoutSetupOperation: Sendable {
    var checkoutID: UUID
    var checkoutMemberID: UUID
    var executionLocation: ExecutionLocation
    var worktreePath: String
    var script: String
}

struct WorkspaceMemberDeletionPreview: Equatable, Sendable {
    var member: WorkspaceCheckoutMember
    var plan: WorkspaceCheckoutCleanupPlan
    var preflight: WorktreeDeletePreflight
    var rootObservation: WorkspaceCheckoutCleanupRootObservation
}

/// Serializes all mutations for a Project.  The gate is shared by Workspace
/// checkout creation and the existing single-worktree entry points.
actor ProjectMutationGate {
    static let shared = ProjectMutationGate()

    private var lockedProjects = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withMutation<Value: Sendable>(
        projectID: String,
        operation: @Sendable () async throws -> Value
    ) async rethrows -> Value {
        await acquire(projectID: projectID)
        do {
            let value = try await operation()
            release(projectID: projectID)
            return value
        } catch {
            release(projectID: projectID)
            throw error
        }
    }

    private func acquire(projectID: String) async {
        guard lockedProjects.contains(projectID) else {
            lockedProjects.insert(projectID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[projectID, default: []].append(continuation)
        }
    }

    private func release(projectID: String) {
        guard var projectWaiters = waiters[projectID], !projectWaiters.isEmpty else {
            lockedProjects.remove(projectID)
            return
        }
        let next = projectWaiters.removeFirst()
        waiters[projectID] = projectWaiters.isEmpty ? nil : projectWaiters
        next.resume()
    }
}

actor WorkspaceCheckoutCoordinator {
    private let store: WorkspaceStore
    private let git: any WorkspaceGitOperating
    private let scripts: any WorkspaceScriptRunning
    private let projectMutationGate: ProjectMutationGate
    private let sessions: any WorkspaceCheckoutSessionStopping
    private let lifecycle: any WorkspaceCheckoutLifecycleOperating
    private let manifests: any WorkspaceCheckoutManifestWriting
    private let observer: any WorkspaceCheckoutObserving
    private var creationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCreationPlans: [UUID: (WorkspaceCheckout, FrozenWorkspaceCheckoutPlan)] = [:]
    private var activeArchives = Set<UUID>()
    private var activeCheckoutDeletions = Set<UUID>()
    private var activeDeletions = Set<String>()
    private var activeForgets = Set<UUID>()
    private var activeRepairs = Set<UUID>()
    private var activeSetups = Set<String>()
    private var liveOperationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(
        store: WorkspaceStore,
        git: any WorkspaceGitOperating = WorkspaceFrozenGitOperator(),
        scripts: any WorkspaceScriptRunning = WorkspaceSetupScriptRunner(),
        projectMutationGate: ProjectMutationGate = .shared,
        sessions: any WorkspaceCheckoutSessionStopping = NoopWorkspaceCheckoutSessionStopper(),
        lifecycle: any WorkspaceCheckoutLifecycleOperating = WorkspaceCheckoutLifecycleOperator(),
        observer: any WorkspaceCheckoutObserving = WorkspaceCheckoutObserver(),
        manifests: (any WorkspaceCheckoutManifestWriting)? = nil
    ) {
        self.store = store
        self.git = git
        self.scripts = scripts
        self.projectMutationGate = projectMutationGate
        self.sessions = sessions
        self.lifecycle = lifecycle
        self.observer = observer
        // Production uses the concrete Git operator and writes the manifest.
        // Narrow test operators opt into a writer explicitly, avoiding any
        // filesystem side effects from synthetic frozen paths.
        self.manifests = manifests ?? (git is WorkspaceFrozenGitOperator
            ? WorkspaceCheckoutManifestWriter()
            : NoopWorkspaceCheckoutManifestWriter())
    }

    func archive(checkoutID: UUID) async throws -> WorkspaceCheckout {
        guard !activeArchives.contains(checkoutID) else {
            throw WorkspaceCheckoutCoordinatorError.operationInProgress
        }
        activeArchives.insert(checkoutID)
        defer {
            activeArchives.remove(checkoutID)
            notifyLiveOperationWaiters(checkoutID: checkoutID)
        }
        // Persist the archive claim first so concurrent lifecycle commands
        // cannot race the owned-process shutdown.
        try await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceCheckoutCoordinatorError.checkoutMissing
            }
            guard state.checkouts[index].operation == .idle || state.checkouts[index].operation == .archiving else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            state.checkouts[index].operation = .archiving
        }
        try await sessions.stopSessions(for: checkoutID)
        try await mutateCheckout(checkoutID) {
            guard $0.operation == .archiving else { return }
            $0.archivedAt = .now
            $0.operation = .idle
        }
        return try await self.checkout(id: checkoutID)
    }

    func unarchive(checkoutID: UUID) async throws -> WorkspaceCheckout {
        let checkout = try await checkout(id: checkoutID)
        guard checkout.operation == .idle else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        try await mutateCheckout(checkoutID) { $0.archivedAt = nil }
        return try await self.checkout(id: checkoutID)
    }

    /// This is a checkpointed request: it takes effect between members and
    /// never supplies a force option to Git.
    func stopAfterCurrentOperations(checkoutID: UUID) async throws {
        try await mutateCheckout(checkoutID) { $0.stopAfterCurrentOperations = true }
    }

    func previewMemberDeletion(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceMemberDeletionPreview {
        let checkout = try await checkout(id: checkoutID)
        guard checkout.archivedAt == nil,
              checkout.operation == .idle
        else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard let member = checkout.members.first(where: { $0.id == memberID }),
              let plan = makeCleanupPlan(checkout: checkout, member: member)
        else { throw WorkspaceCheckoutCoordinatorError.cleanupUnavailable }
        switch await lifecycle.verifyCleanup(plan) {
        case .exactLineage(let lineage) where lineage == plan.expectedLineageID:
            break
        case .missing where member.cleanupOwnership.worktreeCreated:
            let root = await lifecycle.inspectRoot(plan)
            guard root.isContained else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
            return WorkspaceMemberDeletionPreview(
                member: member,
                plan: plan,
                preflight: .init(reasons: [], submoduleLocalState: .none),
                rootObservation: root
            )
        default:
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        let root = await lifecycle.inspectRoot(plan)
        guard root.isContained else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
        let preflight = try await lifecycle.deletePreflight(plan)
        return WorkspaceMemberDeletionPreview(member: member, plan: plan, preflight: preflight, rootObservation: root)
    }

    /// Deletes exactly one attempt-owned worktree after verifying its frozen
    /// location, path, and lineage. The checkout snapshot remains, visibly
    /// Explicitly Deleted, so its frozen creation plan can later recreate it.
    func deleteMember(
        checkoutID: UUID,
        memberID: UUID,
        confirmingRisks: Bool = false,
        checkoutOperationAlreadyClaimed: Bool = false
    ) async throws -> WorkspaceCheckout {
        let deletionKey = setupKey(checkoutID: checkoutID, memberID: memberID)
        guard !activeDeletions.contains(deletionKey) else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        activeDeletions.insert(deletionKey)
        defer {
            activeDeletions.remove(deletionKey)
            notifyLiveOperationWaiters(checkoutID: checkoutID)
        }
        let checkout = try await checkout(id: checkoutID)
        guard checkout.archivedAt == nil,
              checkout.operation == .idle || checkout.operation == .deleting
        else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard let member = checkout.members.first(where: { $0.id == memberID }),
              let cleanupPlan = member.cleanup?.plan ?? makeCleanupPlan(checkout: checkout, member: member)
        else { throw WorkspaceCheckoutCoordinatorError.cleanupUnavailable }
        // Claim and durably freeze the cleanup operation before the first
        // await. A retry retains its original plan/checkpoints verbatim.
        try await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  state.checkouts[index].archivedAt == nil,
                  state.checkouts[index].operation == .idle || state.checkouts[index].operation == .deleting,
                  let memberIndex = state.checkouts[index].members.firstIndex(where: { $0.id == memberID })
            else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
            if state.checkouts[index].operation == .deleting,
               state.checkouts[index].members[memberIndex].cleanup == nil,
               !checkoutOperationAlreadyClaimed {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            state.checkouts[index].operation = .deleting
            if state.checkouts[index].members[memberIndex].cleanup == nil {
                state.checkouts[index].members[memberIndex].cleanup = .init(plan: cleanupPlan)
            }
        }
        do {
            let persisted = try await self.checkout(id: checkoutID)
            guard let current = persisted.members.first(where: { $0.id == memberID }),
                  let frozen = current.cleanup?.plan,
                  frozen == cleanupPlan || current.cleanup?.worktreeRemoved == true
            else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
            let plan = current.cleanup?.plan ?? cleanupPlan
            var worktreeAlreadyRemoved = current.cleanup?.worktreeRemoved == true
            switch await lifecycle.verifyCleanup(plan) {
            case .exactLineage(let lineage) where lineage == plan.expectedLineageID:
                break
            case .missing:
                do {
                    try await projectMutationGate.withMutation(projectID: member.projectID) {
                        try await lifecycle.clearStaleRegistrationForExplicitDeletion(plan)
                    }
                    worktreeAlreadyRemoved = true
                    try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                        $0.cleanup?.worktreeRemoved = true
                        $0.cleanup?.checkpoint = .worktreeRemoved
                    }
                } catch WorkspaceCheckoutCoordinatorError.completedWorktreeReturned {
                    worktreeAlreadyRemoved = false
                }
            default:
                throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
            }
            let root = await lifecycle.inspectRoot(plan)
            guard root.isContained else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
            if !worktreeAlreadyRemoved {
                let preflight = try await lifecycle.deletePreflight(plan)
                guard !preflight.requiresForce || confirmingRisks else {
                    throw WorkspaceCheckoutCoordinatorError.cleanupConfirmationRequired
                }
                let forceTwice = confirmingRisks && preflight.reasons.contains(.locked)
                try await projectMutationGate.withMutation(projectID: member.projectID) {
                    try await lifecycle.removeWorktree(plan, force: confirmingRisks, forceTwice: forceTwice)
                }
                try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                    $0.cleanup?.worktreeRemoved = true
                    $0.cleanup?.checkpoint = .worktreeRemoved
                }
            }
            if plan.branchOwnership == .created {
                if current.cleanup?.branchRemoved == true {
                    try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                        $0.cleanup?.checkpoint = .complete
                    }
                } else {
                    let removed = try await projectMutationGate.withMutation(projectID: member.projectID) {
                        try await lifecycle.deleteMergedBranch(plan)
                    }
                    try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                        $0.cleanup?.branchRemoved = removed
                        $0.cleanup?.checkpoint = removed ? .complete : .branchDeleteAttempted
                    }
                }
            }
            let leftovers = await lifecycle.inspectRoot(plan).leftovers
            try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                $0.cleanup?.sharedRootLeftovers = leftovers
            }
            try await mutateCheckout(checkoutID) { current in
                guard let index = current.members.firstIndex(where: { $0.id == memberID }) else { return }
                current.members[index].availability = .explicitlyDeleted
                current.members[index].checkpoint = .planPersisted
                current.members[index].gitLineageID = nil
                current.members[index].cleanupOwnership = .init()
                current.members[index].recreationSourceCheckpoint = nil
                current.members[index].recreationWorktreeCreationBegan = false
                if !checkoutOperationAlreadyClaimed {
                    current.operation = .idle
                    current.stopAfterCurrentOperations = false
                }
            }
            await refreshManifestIfPresent(checkoutID: checkoutID)
        } catch {
            try? await mutateCheckout(checkoutID) { current in
                if !checkoutOperationAlreadyClaimed {
                    current.operation = .idle
                }
                if let index = current.members.firstIndex(where: { $0.id == memberID }) {
                    current.members[index].cleanup?.checkpoint = .failed
                }
            }
            throw error
        }
        return try await self.checkout(id: checkoutID)
    }

    /// Drops ownership of an identity-conflicted member without touching the
    /// filesystem. The verified deletion path is intentionally unavailable
    /// for conflicts because the worktree at that path is not this snapshot's
    /// frozen member.
    func deleteMemberSnapshot(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        let checkout = try await self.checkout(id: checkoutID)
        guard checkout.archivedAt == nil else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard let member = checkout.members.first(where: { $0.id == memberID }) else {
            throw WorkspaceCheckoutCoordinatorError.checkoutMissing
        }
        let cleanupPlan = member.cleanup?.plan ?? makeCleanupPlan(checkout: checkout, member: member)
        let observedConflict: Bool
        if member.availability == .identityConflict {
            observedConflict = true
        } else if let cleanupPlan {
            switch await lifecycle.verifyCleanup(cleanupPlan) {
            case .identityConflict:
                observedConflict = true
            default:
                observedConflict = false
            }
        } else {
            observedConflict = frozenMember(from: member) == nil
        }
        guard observedConflict else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
        do {
            try await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                      state.checkouts[checkoutIndex].archivedAt == nil,
                      state.checkouts[checkoutIndex].operation == .idle,
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
                else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
                let currentMember = state.checkouts[checkoutIndex].members[memberIndex]
                guard currentMember.availability == .identityConflict
                    || (observedConflict && currentMember == member)
                else {
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                }
                state.checkouts[checkoutIndex].members[memberIndex].availability = .explicitlyDeleted
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .planPersisted
                state.checkouts[checkoutIndex].members[memberIndex].gitLineageID = nil
                state.checkouts[checkoutIndex].members[memberIndex].cleanupOwnership = .init()
                state.checkouts[checkoutIndex].members[memberIndex].recreationSourceCheckpoint = nil
                state.checkouts[checkoutIndex].members[memberIndex].recreationWorktreeCreationBegan = false
                if let cleanupPlan {
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = .init(
                        plan: cleanupPlan,
                        checkpoint: .complete,
                        worktreeRemoved: true,
                        branchRemoved: cleanupPlan.branchOwnership != .created,
                        sharedRootLeftovers: [cleanupPlan.worktreePath]
                    )
                } else {
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                }
            }
        } catch WorkspaceStoreError.recoveryRequired {
            throw WorkspaceCheckoutCoordinatorError.workspaceStateUnavailable
        }
        await refreshManifestIfPresent(checkoutID: checkoutID)
        return try await self.checkout(id: checkoutID)
    }

    /// Repairs a snapshot only when the user chose a candidate that exactly
    /// matches the frozen member destination and lineage. This is not an
    /// adoption path for arbitrary worktrees.
    func useExistingVerifiedCandidate(
        checkoutID: UUID,
        memberID: UUID,
        candidate: WorkspaceRepairCandidate
    ) async throws -> WorkspaceCheckout {
        guard candidate.isExactMatch else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
        let currentCheckout = try await checkout(id: checkoutID)
        guard currentCheckout.archivedAt == nil,
              currentCheckout.operation == .idle
        else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard let currentMember = currentCheckout.members.first(where: { $0.id == memberID }),
              let currentPlan = currentMember.plan,
              currentPlan.checkoutMemberID == currentMember.id,
              currentPlan.destinationPath == candidate.path,
              currentMember.worktreePath == candidate.path,
              currentMember.gitLineageID == candidate.lineageID
        else {
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        guard case .exactLineage(let observedLineage) = await observer.observe(currentMember, in: currentCheckout),
              observedLineage == candidate.lineageID
        else {
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        try await store.mutate { state in
            guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  state.checkouts[checkoutIndex].archivedAt == nil,
                  state.checkouts[checkoutIndex].operation == .idle,
                  let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
            else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
            var member = state.checkouts[checkoutIndex].members[memberIndex]
            guard let plan = member.plan,
                  plan.checkoutMemberID == member.id,
                  plan.destinationPath == candidate.path,
                  member.worktreePath == candidate.path,
                  member.gitLineageID == candidate.lineageID
            else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
            member.availability = .available
            member.cleanup = nil
            if member.checkpoint != .setupComplete,
               member.checkpoint != .failed {
                member.checkpoint = .worktreeCreated
            }
            member.cleanupOwnership.worktreeCreated = true
            state.checkouts[checkoutIndex].members[memberIndex] = member
        }
        await refreshManifestIfPresent(checkoutID: checkoutID)
        return try await self.checkout(id: checkoutID)
    }

    /// Runs member cleanup in snapshot order. A request to stop is honored at
    /// the next member boundary; failed members remain independently visible.
    func deleteCheckout(checkoutID: UUID, confirmingRisks: Bool = false) async throws -> WorkspaceCheckout {
        guard !activeCheckoutDeletions.contains(checkoutID) else {
            throw WorkspaceCheckoutCoordinatorError.operationInProgress
        }
        activeCheckoutDeletions.insert(checkoutID)
        defer {
            activeCheckoutDeletions.remove(checkoutID)
            notifyLiveOperationWaiters(checkoutID: checkoutID)
        }
        try await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceCheckoutCoordinatorError.checkoutMissing
            }
            guard state.checkouts[index].archivedAt == nil,
                  state.checkouts[index].operation == .idle || state.checkouts[index].operation == .deleting
            else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            state.checkouts[index].operation = .deleting
        }
        let initial = try await checkout(id: checkoutID)
        for member in initial.members where member.availability != .explicitlyDeleted {
            let current = try await checkout(id: checkoutID)
            if current.stopAfterCurrentOperations { break }
            do {
                if let currentMember = current.members.first(where: { $0.id == member.id }),
                   canDiscardSnapshotOnlyMember(currentMember) {
                    try await discardSnapshotOnlyMember(checkout: current, member: currentMember)
                } else {
                    _ = try await deleteMember(
                        checkoutID: checkoutID,
                        memberID: member.id,
                        confirmingRisks: confirmingRisks,
                        checkoutOperationAlreadyClaimed: true
                    )
                }
            } catch {
                // One member's risk, failure, or conflict must not erase the
                // independent cleanup opportunity for later members.
                continue
            }
        }
        try? await mutateCheckout(checkoutID) { current in
            guard current.operation == .deleting else { return }
            current.operation = .idle
            current.stopAfterCurrentOperations = false
        }
        return try await checkout(id: checkoutID)
    }

    private func canDiscardSnapshotOnlyMember(_ member: WorkspaceCheckoutMember) -> Bool {
        member.cleanup == nil
            && member.cleanupOwnership.worktreeCreated == false
            && (member.cleanupOwnership.branchOwnership != .created || member.plan != nil)
    }

    private func discardSnapshotOnlyMember(
        checkout: WorkspaceCheckout,
        member: WorkspaceCheckoutMember
    ) async throws {
        if member.cleanupOwnership.branchOwnership == .created,
           let plan = makeSnapshotOnlyCleanupPlan(checkout: checkout, member: member) {
            let branchRemoved = try await projectMutationGate.withMutation(projectID: member.projectID) {
                try await lifecycle.deleteMergedBranch(plan)
            }
            try await mutateCheckout(checkout.id) { current in
                guard let index = current.members.firstIndex(where: { $0.id == member.id }) else { return }
                current.members[index].availability = .explicitlyDeleted
                current.members[index].checkpoint = .planPersisted
                current.members[index].recreationSourceCheckpoint = nil
                current.members[index].recreationWorktreeCreationBegan = false
                current.members[index].cleanup = .init(
                    plan: plan,
                    checkpoint: branchRemoved ? .complete : .branchDeleteAttempted,
                    worktreeRemoved: true,
                    branchRemoved: branchRemoved,
                    sharedRootLeftovers: []
                )
            }
        } else {
            try await mutateCheckout(checkout.id) { current in
                guard let index = current.members.firstIndex(where: { $0.id == member.id }) else { return }
                current.members[index].availability = .explicitlyDeleted
                current.members[index].checkpoint = .planPersisted
                current.members[index].recreationSourceCheckpoint = nil
                current.members[index].recreationWorktreeCreationBegan = false
                current.members[index].cleanup = nil
            }
        }
        await refreshManifestIfPresent(checkoutID: checkout.id)
    }

    /// Forgetting is distinct from deletion: callers may discard a record only
    /// after each attempt-owned worktree has been removed. Branches retained
    /// because they are unmerged deliberately remain user artifacts.
    /// Requires a separate, explicit acknowledgement before dropping a record
    /// whose attempt-created branch was retained because it was unmerged.
    func forget(checkoutID: UUID, confirmedPreserveArtifacts: Bool = false) async throws {
        guard !activeForgets.contains(checkoutID) else {
            throw WorkspaceCheckoutCoordinatorError.operationInProgress
        }
        activeForgets.insert(checkoutID)
        defer {
            activeForgets.remove(checkoutID)
            notifyLiveOperationWaiters(checkoutID: checkoutID)
        }
        let checkout = try await self.checkout(id: checkoutID)
        guard checkout.archivedAt == nil else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard (checkout.operation == .idle || checkout.operation == .deleting),
              checkout.members.allSatisfy({ member in
                  guard let cleanup = member.cleanup else {
                      return confirmedPreserveArtifacts
                          && member.availability == .explicitlyDeleted
                          && member.cleanupOwnership.worktreeCreated == false
                          && member.cleanupOwnership.branchOwnership != .created
                  }
                  guard cleanup.worktreeRemoved,
                        cleanup.sharedRootLeftovers.isEmpty || confirmedPreserveArtifacts
                  else { return false }
                  return cleanup.plan.branchOwnership != .created || cleanup.branchRemoved || confirmedPreserveArtifacts
              })
        else { throw WorkspaceCheckoutCoordinatorError.cleanupIncomplete }
        try await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceCheckoutCoordinatorError.checkoutMissing
            }
            guard state.checkouts[index].archivedAt == nil,
                  state.checkouts[index].operation == .idle || state.checkouts[index].operation == .deleting
            else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            state.checkouts[index].operation = .deleting
        }
        try await sessions.stopSessions(for: checkoutID)
        try await lifecycle.removeCheckoutRootArtifacts(for: checkout)
        try await store.mutate { state in state.checkouts.removeAll { $0.id == checkoutID } }
    }

    /// Surviving snapshots retain their source identity/name and become a
    /// Former Workspace group when the mutable definition disappears.
    func markWorkspaceDeleted(workspaceID: UUID) async throws {
        try await store.mutate { state in
            for index in state.checkouts.indices where state.checkouts[index].workspaceID == workspaceID {
                state.checkouts[index].workspaceID = nil
            }
        }
    }

    /// Persists the complete frozen checkout before scheduling any Git work.
    /// Individual member failures are checkpointed and never cancel siblings.
    func createPersisted(
        workspace: Workspace,
        plan: FrozenWorkspaceCheckoutPlan,
        configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot? = nil
    ) async throws -> WorkspaceCheckout {
        let checkout = try await persistFrozenCheckout(
            workspace: workspace,
            plan: plan,
            configurationSnapshot: configurationSnapshot
        )
        // The complete snapshot is durable before this write and before the
        // first Git mutation. A manifest failure leaves an inspectable
        // checkpointed checkout and cannot result in partial Git artifacts.
        do {
            try await manifests.writeManifest(for: checkout)
        } catch {
            try? await mutateCheckout(checkout.id) { current in
                current.operation = .idle
                current.diagnostics.append(.init(severity: .error, message: "Could not write the Workspace checkout manifest."))
            }
            throw error
        }
        // Return at the durable checkpoint so UI selection and progress are
        // checkout-owned before any member operation starts.
        pendingCreationPlans[checkout.id] = (checkout, plan)
        return checkout
    }

    /// Compatibility entry point for non-UI callers. UI uses the explicit
    /// persisted handoff so selection is observable before Git begins.
    func create(workspace: Workspace, plan: FrozenWorkspaceCheckoutPlan, configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot? = nil) async throws -> WorkspaceCheckout {
        let checkout = try await createPersisted(workspace: workspace, plan: plan, configurationSnapshot: configurationSnapshot)
        beginCreation(checkoutID: checkout.id)
        return checkout
    }

    func beginCreation(checkoutID: UUID) {
        guard let (checkout, plan) = pendingCreationPlans.removeValue(forKey: checkoutID), creationTasks[checkoutID] == nil else { return }
        creationTasks[checkout.id] = Task { [weak self] in
            await self?.executeMembers(of: checkout, plan: plan)
            await self?.finishCreationTask(checkout.id)
        }
    }

    func stopPendingCreationBeforeStart(checkoutID: UUID) async throws -> WorkspaceCheckout {
        pendingCreationPlans.removeValue(forKey: checkoutID)
        try await mutateCheckout(checkoutID) { current in
            guard current.operation == .creating,
                  current.members.allSatisfy({ $0.checkpoint == .planPersisted })
            else { return }
            current.operation = .idle
            current.stopAfterCurrentOperations = false
            current.diagnostics.append(.init(
                severity: .warning,
                message: "Workspace checkout creation was stopped before Git operations started. Use Resume Creation to continue."
            ))
        }
        return try await checkout(id: checkoutID)
    }

    func awaitCreationCompletion(checkoutID: UUID) async {
        await creationTasks[checkoutID]?.value
    }

    func awaitLiveOperations(checkoutID: UUID) async {
        while true {
            if let task = creationTasks[checkoutID] {
                await task.value
                continue
            }
            guard activeRepairs.contains(checkoutID)
                || hasActiveSetup(checkoutID: checkoutID)
                || activeCheckoutDeletions.contains(checkoutID)
                || hasActiveDeletion(checkoutID: checkoutID)
                || activeArchives.contains(checkoutID)
                || activeForgets.contains(checkoutID)
            else {
                return
            }
            await withCheckedContinuation { continuation in
                liveOperationWaiters[checkoutID, default: []].append(continuation)
            }
        }
    }

    private func finishCreationTask(_ checkoutID: UUID) {
        creationTasks[checkoutID] = nil
        notifyLiveOperationWaiters(checkoutID: checkoutID)
    }

    /// Explicitly retries a persisted setup checkpoint. Git creation is not
    /// part of this command, so a relaunch cannot recreate a verified member.
    func retrySetup(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        let setupKey = setupKey(checkoutID: checkoutID, memberID: memberID)
        guard !activeSetups.contains(setupKey) else {
            throw WorkspaceCheckoutCoordinatorError.operationInProgress
        }
        activeSetups.insert(setupKey)
        defer {
            activeSetups.remove(setupKey)
            notifyLiveOperationWaiters(checkoutID: checkoutID)
        }
        let checkout = try await self.checkout(id: checkoutID)
        guard checkout.archivedAt == nil else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard checkout.members.contains(where: { $0.id == memberID }) else {
            throw WorkspaceCheckoutCoordinatorError.checkoutMissing
        }
        let setupResumeVerified: Bool
        if let member = checkout.members.first(where: { $0.id == memberID }) {
            setupResumeVerified = await setupResumeHasExactLineage(checkout: checkout, member: member)
        } else {
            setupResumeVerified = false
        }
        let claimed = try await store.mutate { state -> WorkspaceCheckoutMember? in
            guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
            else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
            guard state.checkouts[checkoutIndex].archivedAt == nil,
                  state.checkouts[checkoutIndex].operation == .idle
            else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            let member = state.checkouts[checkoutIndex].members[memberIndex]
            guard member.availability != .identityConflict,
                  member.checkpoint == .worktreeCreated || member.checkpoint == .setupRunning || (member.checkpoint == .failed && member.cleanupOwnership.worktreeCreated),
                  let plan = member.plan,
                  plan.checkoutMemberID == member.id,
                  plan.projectID == member.projectID,
                  plan.destinationPath == member.worktreePath,
                  !plan.sourceRepositoryPath.isEmpty,
                  !plan.baseReference.isEmpty,
                  !plan.baseCommit.isEmpty
            else { return nil }
            guard setupResumeVerified else {
                return nil
            }
            state.checkouts[checkoutIndex].operation = .repairing
            state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .setupRunning
            return member
        }
        guard let member = claimed else { return checkout }
        let plan = member.plan!
        let frozenMember = FrozenWorkspaceCheckoutPlan.Member(
            checkoutMemberID: plan.checkoutMemberID,
            workspaceMemberID: member.workspaceMemberID,
            projectID: plan.projectID,
            sourceRepositoryPath: plan.sourceRepositoryPath,
            destinationPath: plan.destinationPath,
            baseReference: plan.baseReference,
            baseCommit: plan.baseCommit,
            branchIntent: plan.branchIntent
        )
        do {
            try await runSetupThrowing(member: frozenMember, checkout: checkout, setupAlreadyClaimed: true)
        } catch {
            try? await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkout.id }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == member.id })
                else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .failed
                state.checkouts[checkoutIndex].members[memberIndex].availability = .unavailable
                state.checkouts[checkoutIndex].diagnostics.append(.init(severity: .error, message: "Workspace setup failed for \(state.checkouts[checkoutIndex].members[memberIndex].fallbackProjectName)."))
            }
        }
        await finishScopedRepair(checkoutID: checkoutID, memberIDs: [memberID])
        return try await self.checkout(id: checkoutID)
    }

    /// Explicitly resumes Git creation from the durable frozen plan. Members
    /// that already reached worktree creation, setup success, or an identity
    /// conflict are deliberately excluded.
    func resumeCreation(checkoutID: UUID) async throws -> WorkspaceCheckout {
        try await resumeCreation(checkoutID: checkoutID, memberIDs: nil)
    }

    func resumeCreation(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        try await resumeCreation(checkoutID: checkoutID, memberIDs: [memberID])
    }

    private func resumeCreation(checkoutID: UUID, memberIDs: Set<UUID>?) async throws -> WorkspaceCheckout {
        guard creationTasks[checkoutID] == nil,
              !activeRepairs.contains(checkoutID),
              !hasActiveSetup(checkoutID: checkoutID)
        else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        activeRepairs.insert(checkoutID)
        defer {
            activeRepairs.remove(checkoutID)
            notifyLiveOperationWaiters(checkoutID: checkoutID)
        }
        let checkout = try await self.checkout(id: checkoutID)
        guard checkout.archivedAt == nil else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        if let memberIDs {
            let checkoutMemberIDs = Set(checkout.members.map(\.id))
            guard memberIDs.isSubset(of: checkoutMemberIDs) else {
                throw WorkspaceCheckoutCoordinatorError.checkoutMissing
            }
        }
        let started = try await store.mutate { state -> Bool in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceCheckoutCoordinatorError.checkoutMissing
            }
            guard state.checkouts[index].archivedAt == nil,
                  state.checkouts[index].operation == .idle || state.checkouts[index].operation == .creating || state.checkouts[index].operation == .repairing
            else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            state.checkouts[index].operation = .repairing
            state.checkouts[index].stopAfterCurrentOperations = false
            return true
        }
        guard started else { return checkout }
        do {
            try await manifests.writeManifest(for: checkout)
        } catch {
            try? await mutateCheckout(checkoutID) { current in
                current.operation = .idle
                current.diagnostics.append(.init(severity: .error, message: "Could not write the Workspace checkout manifest."))
            }
            throw error
        }
        var claimedAnyMember = false
        for member in checkout.members {
            if await shouldStopAfterCurrentOperations(checkoutID: checkoutID) { break }
            if let memberIDs, memberIDs.contains(member.id) == false { continue }
            guard member.availability != .identityConflict,
                  let frozenMember = frozenMember(from: member)
            else { continue }
            let plan = member.plan!
            let setupResumeVerified = if member.checkpoint == .setupRunning
                || member.checkpoint == .worktreeCreated
                || failedDuringSetup(checkout: checkout, member: member)
            {
                await setupResumeHasExactLineage(checkout: checkout, member: member)
            } else {
                true
            }
            if member.checkpoint == .setupComplete {
                guard await completedMemberNeedsRecreation(checkout: checkout, member: frozenMember),
                      let cleanupPlan = makeCleanupPlan(checkout: checkout, member: member),
                      try await claimCompletedMemberForRecreation(checkoutID: checkoutID, memberID: member.id, plan: plan)
                else { continue }
                claimedAnyMember = true
                await execute(
                    member: frozenMember,
                    checkout: checkout,
                    staleRegistrationCleanup: cleanupPlan,
                    preservesCompletedMemberOnLockedRegistration: true
                )
                continue
            }
            if member.recreationSourceCheckpoint == .setupComplete,
               (member.checkpoint == .worktreeCreating || member.checkpoint == .failed) {
                let operation = frozenWorktreeOperation(checkout: checkout, member: frozenMember)
                if member.recreationWorktreeCreationBegan == false,
                   let cleanupPlan = makeCleanupPlan(checkout: checkout, member: member),
                   case .exactLineage(let lineageID) = await lifecycle.verifyCleanup(cleanupPlan),
                   lineageID == cleanupPlan.expectedLineageID {
                    try await updateMember(checkoutID: checkoutID, memberID: member.id) { current in
                        current.checkpoint = .setupComplete
                        current.availability = .available
                        current.gitLineageID = lineageID
                        current.recreationSourceCheckpoint = nil
                        current.recreationWorktreeCreationBegan = false
                    }
                    continue
                }
                if let lineageID = try? await git.existingCreatedWorktreeLineage(operation) {
                    if let cleanupPlan = makeCleanupPlan(checkout: checkout, member: member) {
                        try await lifecycle.finalizeStaleRegistrationCleanup(cleanupPlan)
                    }
                    let shouldResumeSetup = member.recreationWorktreeCreationBegan
                    try await updateMember(checkoutID: checkoutID, memberID: member.id) { current in
                        current.checkpoint = shouldResumeSetup ? .worktreeCreated : .setupComplete
                        current.availability = .available
                        current.gitLineageID = lineageID
                        current.recreationSourceCheckpoint = nil
                        current.recreationWorktreeCreationBegan = false
                    }
                    if shouldResumeSetup {
                        await runSetup(member: frozenMember, checkout: checkout)
                    }
                    continue
                }
                guard let cleanupPlan = makeCleanupPlan(checkout: checkout, member: member) else { continue }
                claimedAnyMember = true
                await execute(
                    member: frozenMember,
                    checkout: checkout,
                    staleRegistrationCleanup: cleanupPlan,
                    preservesCompletedMemberOnLockedRegistration: true
                )
                continue
            }
            let claimedCheckpoint = try? await store.mutate { state -> WorkspaceCheckoutCheckpoint? in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == member.id })
                else { return nil }
                let current = state.checkouts[checkoutIndex].members[memberIndex]
                guard current.id == member.id,
                      current.plan == plan
                else { return nil }
                switch current.checkpoint {
                case .planPersisted, .branchPreparing:
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .branchPreparing
                    state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    state.checkouts[checkoutIndex].members[memberIndex].cleanupOwnership = .init()
                    state.checkouts[checkoutIndex].members[memberIndex].gitLineageID = nil
                    return .branchPreparing
                case .branchPrepared, .worktreeCreating:
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .worktreeCreating
                    state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    state.checkouts[checkoutIndex].members[memberIndex].cleanupOwnership.worktreeCreated = true
                    return .worktreeCreating
                case .setupRunning:
                    guard setupResumeVerified else { return nil }
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .setupRunning
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    return .setupRunning
                case .worktreeCreated:
                    guard setupResumeVerified else { return nil }
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .setupRunning
                    state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    return .setupRunning
                case .failed where !current.cleanupOwnership.worktreeCreated:
                    let checkpoint: WorkspaceCheckoutCheckpoint = current.cleanupOwnership.branchOwnership == .unknown ? .branchPreparing : .worktreeCreating
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = checkpoint
                    state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    return checkpoint
                case .failed where current.cleanupOwnership.worktreeCreated:
                    if failedDuringSetup(checkout: state.checkouts[checkoutIndex], member: current) {
                        guard setupResumeVerified else { return nil }
                        state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .setupRunning
                        state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                        state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                        return .setupRunning
                    } else {
                        state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .worktreeCreating
                        state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                        state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                        return .worktreeCreating
                    }
                default:
                    return nil
                }
            }
            guard let claimedCheckpoint else { continue }
            claimedAnyMember = true
            if claimedCheckpoint == .setupRunning {
                await runSetup(member: frozenMember, checkout: checkout)
            } else if claimedCheckpoint == .worktreeCreating {
                let operation = frozenWorktreeOperation(checkout: checkout, member: frozenMember)
                do {
                    if let lineageID = try await git.existingCreatedWorktreeLineage(operation) {
                        try await updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { current in
                            current.checkpoint = .worktreeCreated
                            current.gitLineageID = lineageID
                            let branchOwnership = current.cleanupOwnership.branchOwnership
                            current.cleanupOwnership = .init(
                                worktreeCreated: true,
                                branchOwnership: branchOwnership
                            )
                        }
                        await runSetup(member: frozenMember, checkout: checkout)
                    } else {
                        if member.gitLineageID != nil {
                            guard try await git.frozenWorktreeIsMissing(operation),
                                  let cleanupPlan = makeCleanupPlan(checkout: checkout, member: member)
                            else { continue }
                            await execute(
                                member: frozenMember,
                                checkout: checkout,
                                staleRegistrationCleanup: cleanupPlan
                            )
                            continue
                        }
                        await execute(member: frozenMember, checkout: checkout)
                    }
                } catch {
                    try? await store.mutate { state in
                        guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkout.id }),
                              let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == plan.checkoutMemberID })
                        else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
                        state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .failed
                        state.checkouts[checkoutIndex].members[memberIndex].availability = .unavailable
                        state.checkouts[checkoutIndex].diagnostics.append(.init(severity: .error, message: "Workspace creation failed for \(state.checkouts[checkoutIndex].members[memberIndex].fallbackProjectName)."))
                    }
                    await refreshManifestIfPresent(checkoutID: checkout.id)
                }
            } else {
                await execute(member: frozenMember, checkout: checkout)
            }
        }
        if !claimedAnyMember {
            await clearRepairIfOwned(checkoutID: checkoutID)
        } else if let memberIDs {
            await finishScopedRepair(checkoutID: checkoutID, memberIDs: memberIDs)
        } else {
            await finishIfAllMembersTerminal(checkoutID: checkoutID, owning: .repairing)
        }
        return try await self.checkout(id: checkoutID)
    }

    private func failedDuringSetup(checkout: WorkspaceCheckout, member: WorkspaceCheckoutMember) -> Bool {
        guard member.checkpoint == .failed,
              member.cleanupOwnership.worktreeCreated,
              member.gitLineageID != nil
        else { return false }
        let expectedMessage = "Workspace setup failed for \(member.fallbackProjectName)."
        return checkout.diagnostics.contains { $0.message == expectedMessage }
    }

    private func setupResumeHasExactLineage(checkout: WorkspaceCheckout, member: WorkspaceCheckoutMember) async -> Bool {
        guard let plan = makeCleanupPlan(checkout: checkout, member: member) else { return false }
        switch await lifecycle.verifyCleanup(plan) {
        case .exactLineage(let lineage):
            return lineage == plan.expectedLineageID
        default:
            return false
        }
    }

    private func clearRepairIfOwned(checkoutID: UUID) async {
        try? await mutateCheckout(checkoutID) {
            guard $0.operation == .repairing else { return }
            $0.operation = .idle
            $0.stopAfterCurrentOperations = false
        }
    }

    private func finishScopedRepair(checkoutID: UUID, memberIDs: Set<UUID>) async {
        try? await store.mutate { state in
            guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  state.checkouts[checkoutIndex].operation == .repairing
            else { return }
            let selectedMembers = state.checkouts[checkoutIndex].members.filter { memberIDs.contains($0.id) }
            guard selectedMembers.isEmpty == false,
                  selectedMembers.allSatisfy({ $0.checkpoint == .setupComplete || $0.checkpoint == .failed })
            else { return }
            state.checkouts[checkoutIndex].operation = .idle
            state.checkouts[checkoutIndex].stopAfterCurrentOperations = false
        }
    }

    private func frozenMember(from member: WorkspaceCheckoutMember) -> FrozenWorkspaceCheckoutPlan.Member? {
        guard let plan = member.plan,
              plan.checkoutMemberID == member.id,
              plan.projectID == member.projectID,
              plan.destinationPath == member.worktreePath,
              !plan.sourceRepositoryPath.isEmpty,
              !plan.baseReference.isEmpty,
              !plan.baseCommit.isEmpty
        else { return nil }
        if case .create(let atCommit) = plan.branchIntent, atCommit != plan.baseCommit {
            return nil
        }
        return .init(
            checkoutMemberID: plan.checkoutMemberID,
            workspaceMemberID: member.workspaceMemberID,
            projectID: plan.projectID,
            sourceRepositoryPath: plan.sourceRepositoryPath,
            destinationPath: plan.destinationPath,
            baseReference: plan.baseReference,
            baseCommit: plan.baseCommit,
            branchIntent: plan.branchIntent
        )
    }

    private func frozenWorktreeOperation(
        checkout: WorkspaceCheckout,
        member: FrozenWorkspaceCheckoutPlan.Member
    ) -> WorkspaceFrozenWorktreeOperation {
        WorkspaceFrozenWorktreeOperation(
            checkoutID: checkout.id,
            checkoutMemberID: member.checkoutMemberID,
            projectID: member.projectID,
            executionLocation: checkout.executionLocation,
            sourceRepositoryPath: member.sourceRepositoryPath,
            destinationPath: member.destinationPath,
            branch: checkout.branch,
            baseCommit: member.baseCommit,
            branchIntent: .init(member.branchIntent, baseCommit: member.baseCommit),
            expectedLineageID: expectedLineageID(checkoutID: checkout.id, memberID: member.checkoutMemberID)
        )
    }

    private func expectedLineageID(checkoutID: UUID, memberID: UUID) -> String {
        "workspace-\(checkoutID.uuidString.lowercased())-\(memberID.uuidString.lowercased())"
    }

    private func completedMemberNeedsRecreation(
        checkout: WorkspaceCheckout,
        member: FrozenWorkspaceCheckoutPlan.Member
    ) async -> Bool {
        let operation = frozenWorktreeOperation(checkout: checkout, member: member)
        do {
            return try await projectMutationGate.withMutation(projectID: member.projectID) {
                try await git.frozenWorktreeIsMissing(operation)
            }
        } catch {
            return false
        }
    }

    private func claimCompletedMemberForRecreation(
        checkoutID: UUID,
        memberID: UUID,
        plan: WorkspaceCheckoutMemberPlan
    ) async throws -> Bool {
        let claimed = try await store.mutate { state -> Bool in
            guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
            else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
            let current = state.checkouts[checkoutIndex].members[memberIndex]
            guard current.checkpoint == .setupComplete,
                  current.plan == plan
            else { return false }
            state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .worktreeCreating
            state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
            state.checkouts[checkoutIndex].members[memberIndex].recreationSourceCheckpoint = .setupComplete
            state.checkouts[checkoutIndex].members[memberIndex].recreationWorktreeCreationBegan = false
            state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
            let branchOwnership = current.cleanupOwnership.branchOwnership
            state.checkouts[checkoutIndex].members[memberIndex].cleanupOwnership = .init(
                worktreeCreated: true,
                branchOwnership: branchOwnership
            )
            return true
        }
        if claimed {
            await refreshManifestIfPresent(checkoutID: checkoutID)
        }
        return claimed
    }

    private func persistFrozenCheckout(
        workspace: Workspace,
        plan: FrozenWorkspaceCheckoutPlan,
        configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot?
    ) async throws -> WorkspaceCheckout {
        guard plan.workspaceID == workspace.id,
              plan.executionLocation.normalized == workspace.executionLocation.normalized,
              !plan.rootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              URL(fileURLWithPath: plan.rootPath).standardizedFileURL.path == plan.rootPath,
              case .valid = GitNameValidator.validateBranchName(plan.branch)
        else { throw WorkspaceCheckoutCoordinatorError.incompletePlan }
        guard plan.members.count == workspace.members.count else { throw WorkspaceCheckoutCoordinatorError.incompletePlan }
        guard Set(workspace.members.map(\.id)).count == workspace.members.count,
              Set(plan.members.map(\.workspaceMemberID)).count == plan.members.count,
              Set(plan.members.map(\.checkoutMemberID)).count == plan.members.count
        else { throw WorkspaceCheckoutCoordinatorError.incompletePlan }
        let workspaceMembers = Dictionary(uniqueKeysWithValues: workspace.members.map { ($0.id, $0) })
        let members = try plan.members.map { planned -> WorkspaceCheckoutMember in
            guard let source = workspaceMembers[planned.workspaceMemberID] else {
                throw WorkspaceCheckoutCoordinatorError.planDoesNotMatchWorkspaceMember(planned.workspaceMemberID)
            }
            guard planned.projectID == source.projectID,
                  !planned.sourceRepositoryPath.isEmpty,
                  !planned.destinationPath.isEmpty,
                  !planned.baseReference.isEmpty,
                  !planned.baseCommit.isEmpty
            else { throw WorkspaceCheckoutCoordinatorError.incompletePlan }
            if case .create(let atCommit) = planned.branchIntent, atCommit != planned.baseCommit {
                throw WorkspaceCheckoutCoordinatorError.incompletePlan
            }
            return WorkspaceCheckoutMember(
                id: planned.checkoutMemberID,
                workspaceMemberID: source.id,
                projectID: planned.projectID,
                fallbackProjectName: source.fallbackProjectName,
                fallbackRepositoryRoot: source.fallbackRepositoryRoot,
                worktreePath: planned.destinationPath,
                availability: .pending,
                checkpoint: .planPersisted,
                plan: .init(
                    checkoutMemberID: planned.checkoutMemberID,
                    projectID: planned.projectID,
                    sourceRepositoryPath: planned.sourceRepositoryPath,
                    destinationPath: planned.destinationPath,
                    baseReference: planned.baseReference,
                    baseCommit: planned.baseCommit,
                    branchIntent: planned.branchIntent
                )
            )
        }
        let checkout = WorkspaceCheckout(
            id: plan.checkoutID,
            workspaceID: plan.workspaceID,
            fallbackWorkspaceName: workspace.name,
            executionLocation: plan.executionLocation,
            branch: plan.branch,
            rootPath: plan.rootPath,
            operation: .creating,
            members: members,
            diagnostics: plan.warnings,
            configurationSnapshot: configurationSnapshot
        )
        do {
            try await store.mutate { state in
                guard state.checkouts.contains(where: { $0.id == plan.checkoutID }) == false else {
                    throw WorkspaceCheckoutCoordinatorError.checkoutAlreadyExists
                }
                state.checkouts.append(checkout)
            }
        } catch WorkspaceStoreError.recoveryRequired {
            throw WorkspaceCheckoutCoordinatorError.workspaceStateUnavailable
        }
        return checkout
    }

    private func executeMembers(of checkout: WorkspaceCheckout, plan: FrozenWorkspaceCheckoutPlan) async {
        await withTaskGroup(of: String.self) { group in
            var pending = plan.members
            var activeProjectIDs: Set<String> = []

            func scheduleNextAvailable() -> Bool {
                guard let index = pending.firstIndex(where: { !activeProjectIDs.contains($0.projectID) }) else {
                    return false
                }
                let member = pending.remove(at: index)
                activeProjectIDs.insert(member.projectID)
                group.addTask {
                    await self.execute(member: member, checkout: checkout)
                    return member.projectID
                }
                return true
            }

            if !(await shouldStopAfterCurrentOperations(checkoutID: checkout.id)) {
                for _ in 0 ..< min(4, pending.count) {
                    guard scheduleNextAvailable() else { break }
                }
            }

            while let projectID = await group.next() {
                activeProjectIDs.remove(projectID)
                guard !(await shouldStopAfterCurrentOperations(checkoutID: checkout.id)) else { continue }
                while activeProjectIDs.count < 4, scheduleNextAvailable() {}
            }
        }
        await finishIfAllMembersTerminal(checkoutID: checkout.id, owning: .creating)
    }

    private func execute(
        member plan: FrozenWorkspaceCheckoutPlan.Member,
        checkout: WorkspaceCheckout,
        staleRegistrationCleanup: WorkspaceCheckoutCleanupPlan? = nil,
        preservesCompletedMemberOnLockedRegistration: Bool = false
    ) async {
        let operation = WorkspaceFrozenWorktreeOperation(
            checkoutID: checkout.id,
            checkoutMemberID: plan.checkoutMemberID,
            projectID: plan.projectID,
            executionLocation: checkout.executionLocation,
            sourceRepositoryPath: plan.sourceRepositoryPath,
            destinationPath: plan.destinationPath,
            branch: checkout.branch,
            baseCommit: plan.baseCommit,
            branchIntent: .init(plan.branchIntent, baseCommit: plan.baseCommit),
            expectedLineageID: expectedLineageID(checkoutID: checkout.id, memberID: plan.checkoutMemberID)
        )
        do {
            try await projectMutationGate.withMutation(projectID: plan.projectID) {
                if let staleRegistrationCleanup {
                    try await self.lifecycle.recoverStaleRegistrationCleanup(staleRegistrationCleanup)
                    guard try await self.git.preparedBranchMatchesFrozenBase(operation) else {
                        throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                    }
                    try await self.lifecycle.clearStaleRegistration(staleRegistrationCleanup)
                    if try await self.git.frozenWorktreeIsMissing(operation) == false {
                        guard try await self.git.existingCreatedWorktreeLineage(operation) == operation.expectedLineageID else {
                            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                        }
                        throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
                    }
                }
                if await self.shouldPrepareBranch(checkoutID: checkout.id, memberID: plan.checkoutMemberID) {
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        member.checkpoint = .branchPreparing
                    }
                    let branchAlreadyMatchedFrozenBase = try await self.git.preparedBranchMatchesFrozenBase(operation)
                    if branchAlreadyMatchedFrozenBase == false {
                        try await self.git.prepareBranch(operation)
                    }
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        member.checkpoint = .branchPrepared
                        member.cleanupOwnership.branchOwnership = if plan.branchIntent == .reuse {
                            .reused
                        } else if branchAlreadyMatchedFrozenBase {
                            .unknown
                        } else {
                            .created
                        }
                    }
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        member.checkpoint = .worktreeCreating
                        member.gitLineageID = operation.expectedLineageID
                        member.cleanupOwnership.worktreeCreated = true
                    }
                }
                let existingLineageID = try await self.git.existingCreatedWorktreeLineage(operation)
                if existingLineageID == nil {
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        if member.recreationSourceCheckpoint != nil {
                            member.recreationWorktreeCreationBegan = true
                        }
                    }
                }
                let lineageID = if let existingLineageID {
                    existingLineageID
                } else {
                    try await self.git.createWorktree(operation)
                }
                if let staleRegistrationCleanup {
                    try await self.lifecycle.finalizeStaleRegistrationCleanup(staleRegistrationCleanup)
                }
                try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                    member.checkpoint = .worktreeCreated
                    member.recreationSourceCheckpoint = nil
                    member.recreationWorktreeCreationBegan = false
                    member.gitLineageID = lineageID
                    member.cleanup = nil
                    let branchOwnership = member.cleanupOwnership.branchOwnership
                    member.cleanupOwnership = .init(
                        worktreeCreated: true,
                        branchOwnership: branchOwnership
                    )
                }
            }
            try await runSetupThrowing(member: plan, checkout: checkout)
        } catch {
            let recoveryError = error as? WorkspaceCheckoutCoordinatorError
            let returnedWorktreeMatchesLineage = if recoveryError == .completedWorktreeReturned,
                                                    let member = checkout.members.first(where: { $0.id == plan.checkoutMemberID }),
                                                    let cleanupPlan = makeCleanupPlan(checkout: checkout, member: member),
                                                    case .exactLineage(let lineageID) = await lifecycle.verifyCleanup(cleanupPlan) {
                lineageID == cleanupPlan.expectedLineageID
            } else {
                false
            }
            try? await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkout.id }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == plan.checkoutMemberID })
                else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
                if preservesCompletedMemberOnLockedRegistration,
                   recoveryError == .lockedStaleRegistration || returnedWorktreeMatchesLineage {
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .setupComplete
                    state.checkouts[checkoutIndex].members[memberIndex].availability = .missing
                    state.checkouts[checkoutIndex].members[memberIndex].recreationSourceCheckpoint = nil
                    state.checkouts[checkoutIndex].members[memberIndex].recreationWorktreeCreationBegan = false
                    return
                }
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .failed
                state.checkouts[checkoutIndex].members[memberIndex].availability = .unavailable
                state.checkouts[checkoutIndex].diagnostics.append(.init(severity: .error, message: "Workspace creation failed for \(state.checkouts[checkoutIndex].members[memberIndex].fallbackProjectName)."))
            }
            await refreshManifestIfPresent(checkoutID: checkout.id)
        }
    }

    private func runSetup(member plan: FrozenWorkspaceCheckoutPlan.Member, checkout: WorkspaceCheckout) async {
        do {
            try await runSetupThrowing(member: plan, checkout: checkout)
        } catch {
            try? await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkout.id }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == plan.checkoutMemberID })
                else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .failed
                state.checkouts[checkoutIndex].members[memberIndex].availability = .unavailable
                state.checkouts[checkoutIndex].diagnostics.append(.init(severity: .error, message: "Workspace setup failed for \(state.checkouts[checkoutIndex].members[memberIndex].fallbackProjectName)."))
            }
            await refreshManifestIfPresent(checkoutID: checkout.id)
        }
    }

    private func runSetupThrowing(member plan: FrozenWorkspaceCheckoutPlan.Member, checkout: WorkspaceCheckout, setupAlreadyClaimed: Bool = false) async throws {
        let setupKey = setupKey(checkoutID: checkout.id, memberID: plan.checkoutMemberID)
        if !setupAlreadyClaimed {
            guard !activeSetups.contains(setupKey) else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            activeSetups.insert(setupKey)
        }
        defer {
            if !setupAlreadyClaimed {
                activeSetups.remove(setupKey)
                notifyLiveOperationWaiters(checkoutID: checkout.id)
            }
        }
        let setup = WorkspaceCheckoutSetupOperation(
            checkoutID: checkout.id,
            checkoutMemberID: plan.checkoutMemberID,
            executionLocation: checkout.executionLocation,
            worktreePath: plan.destinationPath,
            script: await setupScript(checkoutID: checkout.id, memberID: plan.checkoutMemberID)
        )
        try await updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
            member.checkpoint = .setupRunning
        }
        try await scripts.runSetup(for: setup)
        try await updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
            member.checkpoint = .setupComplete
            member.availability = .available
        }
    }

    private func setupKey(checkoutID: UUID, memberID: UUID) -> String {
        "\(checkoutID.uuidString):\(memberID.uuidString)"
    }

    private func hasActiveSetup(checkoutID: UUID) -> Bool {
        let prefix = "\(checkoutID.uuidString):"
        return activeSetups.contains { $0.hasPrefix(prefix) }
    }

    private func hasActiveDeletion(checkoutID: UUID) -> Bool {
        let prefix = "\(checkoutID.uuidString):"
        return activeDeletions.contains { $0.hasPrefix(prefix) }
    }

    private func notifyLiveOperationWaiters(checkoutID: UUID) {
        let waiters = liveOperationWaiters.removeValue(forKey: checkoutID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func setupScript(checkoutID: UUID, memberID: UUID) async -> String {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID }),
              let member = checkout.members.first(where: { $0.id == memberID })
        else { return "" }
        let shared = checkout.configurationSnapshot?.shared.worktreeCreateScript ?? ""
        let global = checkout.configurationSnapshot?.shared.globalWorktreeCreateScript ?? ""
        let memberSnapshot = checkout.configurationSnapshot?.members[member.workspaceMemberID]
        let memberScript = memberSnapshot?.setupScript ?? ""
        let sharedInheritedGlobal = shared.inheritsGlobalSetupPrefix(global)
        let memberOnlyScript = sharedInheritedGlobal && memberSnapshot?.setupScriptIncludesInheritedGlobalPrefix == true
            ? memberScript.removingInheritedGlobalSetupPrefix(global)
            : memberScript.trimmingCharacters(in: .whitespacesAndNewlines)
        return [shared, memberOnlyScript].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func updateMember(
        checkoutID: UUID,
        memberID: UUID,
        update: (inout WorkspaceCheckoutMember) -> Void
    ) async throws {
        do {
            try await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
                else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
                update(&state.checkouts[checkoutIndex].members[memberIndex])
            }
            await refreshManifestIfPresent(checkoutID: checkoutID)
        } catch WorkspaceStoreError.recoveryRequired {
            throw WorkspaceCheckoutCoordinatorError.workspaceStateUnavailable
        }
    }

    private func refreshManifestIfPresent(checkoutID: UUID) async {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID })
        else { return }
        if manifests is WorkspaceCheckoutManifestWriter,
           checkout.executionLocation.normalized == .local {
            let manifestURL = URL(fileURLWithPath: checkout.rootPath).appendingPathComponent(WorkspaceCheckoutManifest.fileName)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        }
        do {
            try await manifests.writeManifest(for: checkout)
        } catch {
            return
        }
    }

    private func mutateMember(
        checkoutID: UUID,
        memberID: UUID,
        update: (inout WorkspaceCheckoutMember) -> Void
    ) async throws {
        try await updateMember(checkoutID: checkoutID, memberID: memberID, update: update)
    }

    private func mutateCheckout(
        _ checkoutID: UUID,
        update: (inout WorkspaceCheckout) -> Void
    ) async throws {
        do {
            try await store.mutate { state in
                guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                    throw WorkspaceCheckoutCoordinatorError.checkoutMissing
                }
                update(&state.checkouts[index])
            }
        } catch WorkspaceStoreError.recoveryRequired {
            throw WorkspaceCheckoutCoordinatorError.workspaceStateUnavailable
        }
    }

    private func makeCleanupPlan(
        checkout: WorkspaceCheckout,
        member: WorkspaceCheckoutMember
    ) -> WorkspaceCheckoutCleanupPlan? {
        guard member.cleanupOwnership.worktreeCreated,
              let plan = member.plan,
              plan.checkoutMemberID == member.id,
              plan.projectID == member.projectID,
              plan.destinationPath == member.worktreePath,
              !plan.sourceRepositoryPath.isEmpty,
              let lineage = member.gitLineageID,
              !lineage.isEmpty
        else { return nil }
        return .init(
            checkoutID: checkout.id,
            memberID: member.id,
            executionLocation: checkout.executionLocation,
            projectID: member.projectID,
            sourceRepositoryPath: plan.sourceRepositoryPath,
            baseReference: plan.baseReference,
            baseCommit: plan.baseCommit,
            branchCommit: plan.branchIntent.cleanupCommit(defaulting: plan.baseCommit),
            rootPath: checkout.rootPath,
            managedMemberPaths: checkout.members.map(\.worktreePath),
            worktreePath: plan.destinationPath,
            branch: checkout.branch,
            expectedLineageID: lineage,
            branchOwnership: member.cleanupOwnership.branchOwnership
        )
    }

    private func makeSnapshotOnlyCleanupPlan(
        checkout: WorkspaceCheckout,
        member: WorkspaceCheckoutMember
    ) -> WorkspaceCheckoutCleanupPlan? {
        guard let plan = member.plan,
              plan.checkoutMemberID == member.id,
              plan.projectID == member.projectID,
              plan.destinationPath == member.worktreePath,
              !plan.sourceRepositoryPath.isEmpty
        else { return nil }
        return .init(
            checkoutID: checkout.id,
            memberID: member.id,
            executionLocation: checkout.executionLocation,
            projectID: member.projectID,
            sourceRepositoryPath: plan.sourceRepositoryPath,
            baseReference: plan.baseReference,
            baseCommit: plan.baseCommit,
            branchCommit: plan.branchIntent.cleanupCommit(defaulting: plan.baseCommit),
            rootPath: checkout.rootPath,
            managedMemberPaths: checkout.members.map(\.worktreePath),
            worktreePath: plan.destinationPath,
            branch: checkout.branch,
            expectedLineageID: "",
            branchOwnership: member.cleanupOwnership.branchOwnership
        )
    }

    private func finishIfAllMembersTerminal(checkoutID: UUID, owning operation: WorkspaceCheckoutOperation) async {
        try? await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  state.checkouts[index].operation == operation
            else { return }
            if state.checkouts[index].stopAfterCurrentOperations {
                state.checkouts[index].operation = .idle
                state.checkouts[index].stopAfterCurrentOperations = false
                return
            }
            guard state.checkouts[index].members.allSatisfy({ $0.checkpoint == .setupComplete || $0.checkpoint == .failed }) else { return }
            state.checkouts[index].operation = .idle
        }
    }

    private func shouldPrepareBranch(checkoutID: UUID, memberID: UUID) async -> Bool {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID }),
              let member = checkout.members.first(where: { $0.id == memberID })
        else { return true }
        switch member.checkpoint {
        case .branchPrepared, .worktreeCreating:
            return false
        case .failed:
            return member.cleanupOwnership.branchOwnership == .unknown
        default:
            return true
        }
    }

    private func shouldStopAfterCurrentOperations(checkoutID: UUID) async -> Bool {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID }) else { return true }
        return checkout.stopAfterCurrentOperations
    }

    private func checkout(id: UUID) async throws -> WorkspaceCheckout {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == id })
        else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
        return checkout
    }
}

enum WorkspaceCheckoutCoordinatorError: Error, Equatable, Sendable {
    case workspaceStateUnavailable
    case checkoutAlreadyExists
    case checkoutMissing
    case planDoesNotMatchWorkspaceMember(UUID)
    case workspaceIDMismatch
    case incompletePlan
    case operationInProgress
    case cleanupUnavailable
    case cleanupIdentityConflict
    case cleanupIncomplete
    case cleanupConfirmationRequired
    case lockedStaleRegistration
    case completedWorktreeReturned
}

extension String {
    func inheritsGlobalSetupPrefix(_ global: String) -> Bool {
        let global = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !global.isEmpty, !script.isEmpty else { return false }
        return script == global || script.hasPrefix(global + "\n")
    }

    func removingInheritedGlobalSetupPrefix(_ global: String) -> String {
        let global = global.trimmingCharacters(in: .whitespacesAndNewlines)
        let script = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !global.isEmpty, !script.isEmpty else { return script }
        if script == global { return "" }
        let prefix = global + "\n"
        if script.hasPrefix(prefix) {
            return String(script.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return script
    }
}

struct WorkspaceFrozenGitOperator: WorkspaceGitOperating {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        try await WorktreeService().prepareFrozenBranch(
            repoPath: URL(fileURLWithPath: operation.sourceRepositoryPath),
            branch: operation.branch,
            intent: operation.branchIntent,
            remoteHost: operation.executionLocation.normalized.sshHost,
            usesRemoteHostRegistry: operation.executionLocation.normalized != .local
        )
    }

    func preparedBranchMatchesFrozenBase(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool {
        switch operation.executionLocation.normalized {
        case .local:
            let result = try await Process.git(
                ["rev-parse", "--verify", "refs/heads/\(operation.branch)^{commit}"],
                cwd: URL(fileURLWithPath: operation.sourceRepositoryPath),
                usesRemoteHostRegistry: false
            )
            return result.exitCode == 0
                && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operation.baseCommit
        case .ssh(let host):
            let branch = SSHCommand.shellQuote("refs/heads/\(operation.branch)^{commit}")
            let command = "git -C \(SSHCommand.shellQuote(operation.sourceRepositoryPath)) rev-parse --verify \(branch)"
            let result = try await WorkspaceRemoteTransport().run(host: host, command: command)
            return result.exitCode == 0
                && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operation.baseCommit
        }
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        let worktree = try await WorktreeService().addFrozen(
            repoPath: URL(fileURLWithPath: operation.sourceRepositoryPath),
            branch: operation.branch,
            destination: URL(fileURLWithPath: operation.destinationPath),
            projectId: operation.projectID,
            intent: operation.branchIntent,
            expectedLineageID: operation.expectedLineageID,
            remoteHost: operation.executionLocation.normalized.sshHost,
            usesRemoteHostRegistry: operation.executionLocation.normalized != .local
        )
        return worktree.lineageID
    }

    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        switch operation.executionLocation.normalized {
        case .local:
            let destination = URL(fileURLWithPath: operation.destinationPath)
            guard Self.pathEntryExistsOrIsSymlink(destination.path) else { return nil }
            let head = try await Process.git(["rev-parse", "--verify", "HEAD^{commit}"], cwd: destination, usesRemoteHostRegistry: false)
            guard head.exitCode == 0,
                  head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operation.baseCommit
            else { return nil }
            let branch = try await Process.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: destination, usesRemoteHostRegistry: false)
            guard branch.exitCode == 0,
                  branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operation.branch
            else { return nil }
            if let lineage = WorktreeService.existingLocalLineageID(forWorktreeAt: destination) {
                return operation.expectedLineageID.map { $0 == lineage ? lineage : nil } ?? lineage
            }
            return nil
        case .ssh(let host):
            let path = SSHCommand.shellQuote(operation.destinationPath)
            let branch = SSHCommand.shellQuote(operation.branch)
            let commit = SSHCommand.shellQuote(operation.baseCommit)
            let markerCommand = "d=$(git -C \"$p\" rev-parse --absolute-git-dir) || exit 5; f=\"$d/alas-worktree-lineage\"; test -s \"$f\" || exit 6; head -n 1 \"$f\""
            let command = "p=\(path); b=\(branch); c=\(commit); test -d \"$p\" || exit 2; [ \"$(git -C \"$p\" rev-parse --verify HEAD^{commit})\" = \"$c\" ] || exit 3; [ \"$(git -C \"$p\" rev-parse --abbrev-ref HEAD)\" = \"$b\" ] || exit 4; \(markerCommand)"
            let result = try await WorkspaceRemoteTransport().run(host: host, command: command)
            guard result.exitCode == 0 else { return nil }
            guard let lineage = WorktreeService.normalizedLineageID(result.stdout) else { return nil }
            return operation.expectedLineageID.map { $0 == lineage ? lineage : nil } ?? lineage
        }
    }

    func frozenWorktreeIsMissing(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> Bool {
        switch operation.executionLocation.normalized {
        case .local:
            return Self.pathEntryExistsOrIsSymlink(operation.destinationPath) == false
        case .ssh(let host):
            let path = SSHCommand.shellQuote(operation.destinationPath)
            let result = try await WorkspaceRemoteTransport().run(host: host, command: "p=\(path); test -e \"$p\" || test -L \"$p\"")
            return result.exitCode == 1
        }
    }

    static func pathEntryExistsOrIsSymlink(_ path: String) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}

struct WorkspaceSetupScriptRunner: WorkspaceScriptRunning {
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws {
        guard !operation.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch operation.executionLocation.normalized {
        case .local:
            let result = try await Process.run("/bin/zsh", args: ["-c", operation.script], cwd: URL(fileURLWithPath: operation.worktreePath))
            guard result.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(result.stderr) }
        case .ssh(let host):
            let result = try await RemoteExec.run(host: host, cwd: operation.worktreePath, command: operation.script)
            guard result.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(result.stderr) }
        }
    }
}

/// The concrete lifecycle operator intentionally delegates the exact lineage
/// check to the read-only observer and never asks `remove` to delete a branch.
struct WorkspaceCheckoutLifecycleOperator: WorkspaceCheckoutLifecycleOperating {
    private let remote: WorkspaceRemoteTransport
    private static let staleRegistrationTombstoneMarker = "alas-stale-registration-tombstone"
    private static let staleRegistrationOriginalNameMarker = "alas-stale-registration-original-name"

    init(remote: WorkspaceRemoteTransport = .init()) {
        self.remote = remote
    }

    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight {
        switch plan.executionLocation.normalized {
        case .local:
            return try await WorktreeService().deletePreflight(
                worktreePath: URL(fileURLWithPath: plan.worktreePath),
                usesRemoteHostRegistry: false
            )
        case .ssh(let host):
            return try await remoteDeletePreflight(plan, host: host)
        }
    }

    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation {
        switch plan.executionLocation.normalized {
        case .local:
            let root = URL(fileURLWithPath: plan.rootPath).resolvingSymlinksInPath().standardizedFileURL
            let member = URL(fileURLWithPath: plan.worktreePath).resolvingSymlinksInPath().standardizedFileURL
            guard member.path.hasPrefix(root.path + "/") else { return .init(isContained: false, leftovers: []) }
            var managedNames = Set(plan.managedMemberPaths.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.lastPathComponent
            })
            managedNames.insert(WorkspaceCheckoutManifest.fileName)
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
                .filter { !managedNames.contains($0) }
                .sorted() ?? []
            return .init(isContained: true, leftovers: leftovers)
        case .ssh(let host):
            return await remoteInspectRoot(plan, host: host)
        }
    }

    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation {
        let member = WorkspaceCheckoutMember(
            id: plan.memberID,
            workspaceMemberID: UUID(),
            projectID: plan.projectID,
            fallbackProjectName: "",
            fallbackRepositoryRoot: plan.sourceRepositoryPath,
            worktreePath: plan.worktreePath,
            gitLineageID: plan.expectedLineageID,
            plan: .init(checkoutMemberID: plan.memberID, projectID: plan.projectID, sourceRepositoryPath: plan.sourceRepositoryPath, destinationPath: plan.worktreePath, baseReference: plan.baseReference, baseCommit: plan.baseCommit, branchIntent: .reuse)
        )
        let checkout = WorkspaceCheckout(id: plan.checkoutID, workspaceID: nil, fallbackWorkspaceName: "", executionLocation: plan.executionLocation, branch: plan.branch, rootPath: URL(fileURLWithPath: plan.worktreePath).deletingLastPathComponent().path, members: [member])
        return await WorkspaceCheckoutObserver().observe(member, in: checkout)
    }

    func clearStaleRegistration(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        try await clearStaleRegistration(plan, unlockLocked: false)
    }

    func clearStaleRegistrationForExplicitDeletion(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        try await clearStaleRegistration(plan, unlockLocked: true)
    }

    func recoverStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        switch plan.executionLocation.normalized {
        case .local:
            try await Self.recoverLocalInterruptedStaleRegistrationTombstone(
                repo: URL(fileURLWithPath: plan.sourceRepositoryPath),
                destination: URL(fileURLWithPath: plan.worktreePath),
                expectedLineageID: plan.expectedLineageID
            )
        case .ssh(let host):
            let recovery = try await remote.run(
                host: host,
                command: Self.remoteInterruptedStaleRegistrationTombstoneRecoveryCommand(plan)
            )
            switch recovery.exitCode {
            case 0:
                break
            case 13:
                throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
            default:
                throw WorktreeService.WorktreeError.gitFailed(recovery.stderr)
            }
        }
    }

    func finalizeStaleRegistrationCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async throws {
        switch plan.executionLocation.normalized {
        case .local:
            let repo = URL(fileURLWithPath: plan.sourceRepositoryPath)
            let destination = URL(fileURLWithPath: plan.worktreePath)
            guard let tombstone = try await Self.staleRegistrationTombstoneIfPresent(
                repo: repo,
                destination: destination
            ) else { return }
            guard Self.staleRegistrationTombstoneLineageID(tombstone) == plan.expectedLineageID else { return }
            guard Self.staleRegistrationLineageID(tombstone) == plan.expectedLineageID else {
                throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
            }
            try FileManager.default.removeItem(at: tombstone)
            try? FileManager.default.removeItem(at: tombstone.deletingLastPathComponent())
        case .ssh(let host):
            let cleanup = try await remote.run(
                host: host,
                command: Self.remoteFinalizeStaleRegistrationCleanupCommand(plan)
            )
            switch cleanup.exitCode {
            case 0:
                break
            case 13:
                throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
            default:
                throw WorktreeService.WorktreeError.gitFailed(cleanup.stderr)
            }
        }
    }

    private func clearStaleRegistration(_ plan: WorkspaceCheckoutCleanupPlan, unlockLocked: Bool) async throws {
        switch plan.executionLocation.normalized {
        case .local:
            let repo = URL(fileURLWithPath: plan.sourceRepositoryPath)
            let destination = URL(fileURLWithPath: plan.worktreePath)
            var registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
            guard registrations.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(registrations.stderr) }
            if unlockLocked,
               let tombstone = try await Self.staleRegistrationTombstoneIfPresent(repo: repo, destination: destination) {
                guard Self.staleRegistrationTombstoneLineageID(tombstone) == plan.expectedLineageID,
                      Self.staleRegistrationLineageID(tombstone) == plan.expectedLineageID
                else { throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict }
                try FileManager.default.removeItem(at: tombstone)
                try? FileManager.default.removeItem(at: tombstone.deletingLastPathComponent())
            }
            if !unlockLocked {
                try await Self.recoverLocalInterruptedStaleRegistrationTombstone(
                    repo: repo,
                    destination: destination,
                    expectedLineageID: plan.expectedLineageID
                )
                registrations = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
                guard registrations.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(registrations.stderr) }
            }
            guard Self.porcelainContainsWorktree(registrations.stdout, path: plan.worktreePath) else { return }
            if Self.porcelainWorktreeIsLocked(registrations.stdout, path: plan.worktreePath) {
                guard unlockLocked else { throw WorkspaceCheckoutCoordinatorError.lockedStaleRegistration }
            }
            guard WorkspaceFrozenGitOperator.pathEntryExistsOrIsSymlink(destination.path) == false else {
                throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
            }
            if unlockLocked {
                let adminDirectory = try await Self.staleRegistrationAdminDirectory(
                    repo: repo,
                    destination: destination
                )
                guard Self.staleRegistrationLineageID(adminDirectory) == plan.expectedLineageID else {
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                }
                guard WorkspaceFrozenGitOperator.pathEntryExistsOrIsSymlink(destination.path) == false else {
                    throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
                }
                let remove = try await Process.git(
                    ["worktree", "remove", "-f", "-f", "--", destination.path],
                    cwd: repo,
                    usesRemoteHostRegistry: false
                )
                guard remove.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(remove.stderr) }
            } else {
                try await Self.removeLocalStaleRegistrationMetadata(
                    repo: repo,
                    destination: destination,
                    expectedLineageID: plan.expectedLineageID
                )
            }
            let refreshed = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
            guard refreshed.exitCode == 0,
                  !Self.porcelainContainsWorktree(refreshed.stdout, path: destination.path)
            else { throw WorktreeService.WorktreeError.gitFailed(refreshed.stderr) }
        case .ssh(let host):
            let repo = SSHCommand.shellQuote(plan.sourceRepositoryPath)
            var registrations = try await remote.run(host: host, command: "git -C \(repo) worktree list --porcelain")
            guard registrations.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(registrations.stderr) }
            if unlockLocked {
                let cleanup = try await remote.run(
                    host: host,
                    command: Self.remoteFinalizeStaleRegistrationCleanupCommand(plan)
                )
                switch cleanup.exitCode {
                case 0:
                    break
                case 13:
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                default:
                    throw WorktreeService.WorktreeError.gitFailed(cleanup.stderr)
                }
                registrations = try await remote.run(host: host, command: "git -C \(repo) worktree list --porcelain")
                guard registrations.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(registrations.stderr) }
            }
            if !unlockLocked {
                let recovery = try await remote.run(
                    host: host,
                    command: Self.remoteInterruptedStaleRegistrationTombstoneRecoveryCommand(plan)
                )
                switch recovery.exitCode {
                case 0:
                    break
                case 13:
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                default:
                    throw WorktreeService.WorktreeError.gitFailed(recovery.stderr)
                }
                registrations = try await remote.run(host: host, command: "git -C \(repo) worktree list --porcelain")
                guard registrations.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(registrations.stderr) }
            }
            guard Self.porcelainContainsWorktree(registrations.stdout, path: plan.worktreePath) else { return }
            if Self.porcelainWorktreeIsLocked(registrations.stdout, path: plan.worktreePath) {
                guard unlockLocked else { throw WorkspaceCheckoutCoordinatorError.lockedStaleRegistration }
            }
            let destination = SSHCommand.shellQuote(plan.worktreePath)
            let exists = try await remote.run(host: host, command: "p=\(destination); test -e \"$p\" || test -L \"$p\"")
            if exists.exitCode == 0 {
                throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
            }
            guard exists.exitCode == 1 else { throw WorktreeService.WorktreeError.gitFailed(exists.stderr) }
            if unlockLocked {
                let lineage = try await remote.run(
                    host: host,
                    command: Self.remoteStaleRegistrationLineageValidationCommand(plan)
                )
                switch lineage.exitCode {
                case 0:
                    break
                case 13:
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                default:
                    throw WorktreeService.WorktreeError.gitFailed(lineage.stderr)
                }
                let recheck = try await remote.run(host: host, command: "p=\(destination); test -e \"$p\" || test -L \"$p\"")
                if recheck.exitCode == 0 {
                    throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
                }
                guard recheck.exitCode == 1 else { throw WorktreeService.WorktreeError.gitFailed(recheck.stderr) }
                let remove = try await remote.run(
                    host: host,
                    command: "git -C \(repo) worktree remove -f -f -- \(SSHCommand.shellQuote(plan.worktreePath))"
                )
                guard remove.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(remove.stderr) }
            } else {
                let cleanup = try await remote.run(
                    host: host,
                    command: Self.remoteStaleRegistrationMetadataCleanupCommand(plan)
                )
                switch cleanup.exitCode {
                case 0:
                    break
                case 9:
                    throw WorkspaceCheckoutCoordinatorError.lockedStaleRegistration
                case 10:
                    throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
                case 13:
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                default:
                    throw WorktreeService.WorktreeError.gitFailed(cleanup.stderr)
                }
            }
            let refreshed = try await remote.run(host: host, command: "git -C \(repo) worktree list --porcelain")
            guard refreshed.exitCode == 0,
                  !Self.porcelainContainsWorktree(refreshed.stdout, path: plan.worktreePath)
            else { throw WorktreeService.WorktreeError.gitFailed(refreshed.stderr) }
        }
    }

    private static func recoverLocalInterruptedStaleRegistrationTombstone(
        repo: URL,
        destination: URL,
        expectedLineageID: String
    ) async throws {
        guard let adminDirectory = try await staleRegistrationTombstoneIfPresent(
            repo: repo,
            destination: destination
        ) else { return }
        guard adminDirectory.lastPathComponent.contains(".alas-removing-") else { return }
        guard FileManager.default.fileExists(
            atPath: adminDirectory.appendingPathComponent(Self.staleRegistrationTombstoneMarker).path
        ) else { return }
        guard staleRegistrationTombstoneLineageID(adminDirectory) == expectedLineageID else {
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        guard staleRegistrationLineageID(adminDirectory) == expectedLineageID else {
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        guard let restoredName = staleRegistrationOriginalAdminName(adminDirectory) else {
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        let restoredDirectory = adminDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(restoredName)
        guard !FileManager.default.fileExists(atPath: restoredDirectory.path) else {
            throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
        }
        try FileManager.default.moveItem(at: adminDirectory, to: restoredDirectory)
        try? FileManager.default.removeItem(at: restoredDirectory.appendingPathComponent(Self.staleRegistrationTombstoneMarker))
        try? FileManager.default.removeItem(at: restoredDirectory.appendingPathComponent(Self.staleRegistrationOriginalNameMarker))
        try? FileManager.default.removeItem(at: adminDirectory.deletingLastPathComponent())
    }

    private static func removeLocalStaleRegistrationMetadata(
        repo: URL,
        destination: URL,
        expectedLineageID: String
    ) async throws {
        let adminDirectory = try await staleRegistrationAdminDirectory(
            repo: repo,
            destination: destination
        )
        let removingDirectory = adminDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("alas-stale-worktree-tombstones", isDirectory: true)
            .appendingPathComponent("\(adminDirectory.lastPathComponent).alas-removing-\(UUID().uuidString)")
        let marker = adminDirectory.appendingPathComponent(Self.staleRegistrationTombstoneMarker)
        let originalNameMarker = adminDirectory.appendingPathComponent(Self.staleRegistrationOriginalNameMarker)
        try "\(expectedLineageID)\n".write(to: marker, atomically: true, encoding: .utf8)
        try "\(adminDirectory.lastPathComponent)\n".write(to: originalNameMarker, atomically: true, encoding: .utf8)
        do {
            try FileManager.default.createDirectory(
                at: removingDirectory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: adminDirectory, to: removingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: originalNameMarker)
            throw error
        }
        do {
            if FileManager.default.fileExists(atPath: removingDirectory.appendingPathComponent("locked").path) {
                try restoreLocalStaleRegistrationTombstone(removingDirectory, to: adminDirectory)
                throw WorkspaceCheckoutCoordinatorError.lockedStaleRegistration
            }
            guard staleRegistrationLineageID(removingDirectory) == expectedLineageID else {
                try restoreLocalStaleRegistrationTombstone(removingDirectory, to: adminDirectory)
                throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
            }
            if WorkspaceFrozenGitOperator.pathEntryExistsOrIsSymlink(destination.path) {
                try restoreLocalStaleRegistrationTombstone(removingDirectory, to: adminDirectory)
                throw WorkspaceCheckoutCoordinatorError.completedWorktreeReturned
            }
        } catch {
            if FileManager.default.fileExists(atPath: removingDirectory.path),
               !FileManager.default.fileExists(atPath: adminDirectory.path) {
                try? restoreLocalStaleRegistrationTombstone(removingDirectory, to: adminDirectory)
            }
            throw error
        }
    }

    private static func restoreLocalStaleRegistrationTombstone(_ tombstone: URL, to adminDirectory: URL) throws {
        try FileManager.default.moveItem(at: tombstone, to: adminDirectory)
        try? FileManager.default.removeItem(at: adminDirectory.appendingPathComponent(Self.staleRegistrationTombstoneMarker))
        try? FileManager.default.removeItem(at: adminDirectory.appendingPathComponent(Self.staleRegistrationOriginalNameMarker))
    }

    private static func staleRegistrationAdminDirectory(
        repo: URL,
        destination: URL
    ) async throws -> URL {
        guard let directory = try await staleRegistrationAdminDirectoryIfPresent(repo: repo, destination: destination) else {
            throw WorktreeService.WorktreeError.gitFailed("Expected one stale worktree registration for \(destination.path), found 0.")
        }
        return directory
    }

    private static func staleRegistrationTombstoneIfPresent(
        repo: URL,
        destination: URL
    ) async throws -> URL? {
        let commonDir = try await commonGitDirectory(repo: repo)
        let tombstonesDir = commonDir.appendingPathComponent("alas-stale-worktree-tombstones", isDirectory: true)
        return try staleRegistrationDirectoryIfPresent(in: tombstonesDir, destination: destination)
    }

    private static func staleRegistrationAdminDirectoryIfPresent(
        repo: URL,
        destination: URL
    ) async throws -> URL? {
        let commonDir = try await commonGitDirectory(repo: repo)
        let worktreesDir = commonDir.appendingPathComponent("worktrees")
        return try staleRegistrationDirectoryIfPresent(in: worktreesDir, destination: destination)
    }

    private static func commonGitDirectory(repo: URL) async throws -> URL {
        let commonDirResult = try await Process.git(
            ["rev-parse", "--git-common-dir"],
            cwd: repo,
            usesRemoteHostRegistry: false
        )
        guard commonDirResult.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(commonDirResult.stderr) }
        let commonDirText = commonDirResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (commonDirText.hasPrefix("/")
            ? URL(fileURLWithPath: commonDirText)
            : repo.appendingPathComponent(commonDirText))
            .standardizedFileURL
    }

    private static func staleRegistrationDirectoryIfPresent(
        in directory: URL,
        destination: URL
    ) throws -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let expectedGitdirs = gitdirPathAliases(for: destination)
        var matches: [URL] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let gitdir = entry.appendingPathComponent("gitdir")
            guard let content = try? String(contentsOf: gitdir, encoding: .utf8) else { continue }
            if expectedGitdirs.contains(content.trimmingCharacters(in: .whitespacesAndNewlines)) {
                matches.append(entry)
            }
        }
        if matches.count > 1 {
            throw WorktreeService.WorktreeError.gitFailed("Expected one stale worktree registration for \(destination.path), found \(matches.count).")
        }
        return matches.first
    }

    private static func staleRegistrationLineageID(_ adminDirectory: URL) -> String? {
        let marker = adminDirectory.appendingPathComponent("alas-worktree-lineage")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return WorktreeService.normalizedLineageID(text)
    }

    private static func staleRegistrationTombstoneLineageID(_ adminDirectory: URL) -> String? {
        let marker = adminDirectory.appendingPathComponent(Self.staleRegistrationTombstoneMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return WorktreeService.normalizedLineageID(text)
    }

    private static func staleRegistrationOriginalAdminName(_ adminDirectory: URL) -> String? {
        let marker = adminDirectory.appendingPathComponent(Self.staleRegistrationOriginalNameMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    private static func gitdirPathAliases(for destination: URL) -> Set<String> {
        var aliases = Set([
            destination.appendingPathComponent(".git").standardizedFileURL.path,
            destination.resolvingSymlinksInPath().appendingPathComponent(".git").standardizedFileURL.path,
        ])
        for path in Array(aliases) {
            if path.hasPrefix("/private/var/") {
                aliases.insert(String(path.dropFirst("/private".count)))
            } else if path.hasPrefix("/var/") {
                aliases.insert("/private\(path)")
            }
        }
        return aliases
    }

    private static func remoteStaleRegistrationMetadataCleanupCommand(_ plan: WorkspaceCheckoutCleanupPlan) -> String {
        let repo = SSHCommand.shellQuote(plan.sourceRepositoryPath)
        let destination = SSHCommand.shellQuote(plan.worktreePath)
        let expectedLineageID = SSHCommand.shellQuote(plan.expectedLineageID)
        let tombstoneMarker = SSHCommand.shellQuote(Self.staleRegistrationTombstoneMarker)
        let originalNameMarker = SSHCommand.shellQuote(Self.staleRegistrationOriginalNameMarker)
        return """
        repo=\(repo); target=\(destination); expected=\(expectedLineageID); marker_name=\(tombstoneMarker); original_name_marker=\(originalNameMarker); common=$(git -C "$repo" rev-parse --git-common-dir) || exit $?; case "$common" in /*) ;; *) common="$repo/$common" ;; esac; found=; for admin in "$common"/worktrees/*; do [ -d "$admin" ] || continue; [ -f "$admin/gitdir" ] || continue; IFS= read -r gitdir < "$admin/gitdir" || continue; [ "$gitdir" = "$target/.git" ] || continue; [ -z "$found" ] || exit 11; found="$admin"; done; [ -n "$found" ] || exit 12; [ -e "$found/locked" ] && exit 9; f="$found/alas-worktree-lineage"; [ -s "$f" ] || exit 13; IFS= read -r lineage < "$f" || exit 13; [ "$lineage" = "$expected" ] || exit 13; if [ -e "$target" ] || [ -L "$target" ]; then exit 10; fi; marker="$found/$marker_name"; original_marker="$found/$original_name_marker"; printf '%s\\n' "$expected" > "$marker" || exit $?; printf '%s\\n' "${found##*/}" > "$original_marker" || { rm -f -- "$marker"; exit 1; }; tomb_root="$common/alas-stale-worktree-tombstones"; mkdir -p "$tomb_root" || { rm -f -- "$marker" "$original_marker"; exit 1; }; tomb="$tomb_root/${found##*/}.alas-removing.$$"; if ! mv "$found" "$tomb"; then rm -f -- "$marker" "$original_marker"; exit 1; fi; restore() { mv "$tomb" "$found" || exit $?; rm -f -- "$found/$marker_name" "$found/$original_name_marker"; }; if [ -e "$tomb/locked" ]; then restore; exit 9; fi; f="$tomb/alas-worktree-lineage"; [ -s "$f" ] || { restore; exit 13; }; IFS= read -r lineage < "$f" || { restore; exit 13; }; [ "$lineage" = "$expected" ] || { restore; exit 13; }; if [ -e "$target" ] || [ -L "$target" ]; then restore; exit 10; fi
        """
    }

    private static func remoteStaleRegistrationLineageValidationCommand(_ plan: WorkspaceCheckoutCleanupPlan) -> String {
        let repo = SSHCommand.shellQuote(plan.sourceRepositoryPath)
        let destination = SSHCommand.shellQuote(plan.worktreePath)
        let expectedLineageID = SSHCommand.shellQuote(plan.expectedLineageID)
        return """
        repo=\(repo); target=\(destination); expected=\(expectedLineageID); common=$(git -C "$repo" rev-parse --git-common-dir) || exit $?; case "$common" in /*) ;; *) common="$repo/$common" ;; esac; found=; for admin in "$common"/worktrees/*; do [ -d "$admin" ] || continue; [ -f "$admin/gitdir" ] || continue; IFS= read -r gitdir < "$admin/gitdir" || continue; [ "$gitdir" = "$target/.git" ] || continue; [ -z "$found" ] || exit 13; found="$admin"; done; [ -n "$found" ] || exit 12; f="$found/alas-worktree-lineage"; [ -s "$f" ] || exit 13; IFS= read -r lineage < "$f" || exit 13; [ "$lineage" = "$expected" ] || exit 13
        """
    }

    private static func remoteFinalizeStaleRegistrationCleanupCommand(_ plan: WorkspaceCheckoutCleanupPlan) -> String {
        let repo = SSHCommand.shellQuote(plan.sourceRepositoryPath)
        let destination = SSHCommand.shellQuote(plan.worktreePath)
        let expectedLineageID = SSHCommand.shellQuote(plan.expectedLineageID)
        let tombstoneMarker = SSHCommand.shellQuote(Self.staleRegistrationTombstoneMarker)
        let originalNameMarker = SSHCommand.shellQuote(Self.staleRegistrationOriginalNameMarker)
        return """
        repo=\(repo); target=\(destination); expected=\(expectedLineageID); marker_name=\(tombstoneMarker); original_name_marker=\(originalNameMarker); common=$(git -C "$repo" rev-parse --git-common-dir) || exit $?; case "$common" in /*) ;; *) common="$repo/$common" ;; esac; found=; for admin in "$common"/alas-stale-worktree-tombstones/*; do [ -d "$admin" ] || continue; [ -f "$admin/gitdir" ] || continue; IFS= read -r gitdir < "$admin/gitdir" || continue; [ "$gitdir" = "$target/.git" ] || continue; marker="$admin/$marker_name"; [ -s "$marker" ] || continue; [ -z "$found" ] || exit 13; found="$admin"; done; [ -n "$found" ] || exit 0; marker="$found/$marker_name"; IFS= read -r tombstone_lineage < "$marker" || exit 13; [ "$tombstone_lineage" = "$expected" ] || exit 13; f="$found/alas-worktree-lineage"; [ -s "$f" ] || exit 13; IFS= read -r lineage < "$f" || exit 13; [ "$lineage" = "$expected" ] || exit 13; rm -rf -- "$found"; rmdir "$common/alas-stale-worktree-tombstones" 2>/dev/null || true
        """
    }

    private static func remoteInterruptedStaleRegistrationTombstoneRecoveryCommand(_ plan: WorkspaceCheckoutCleanupPlan) -> String {
        let repo = SSHCommand.shellQuote(plan.sourceRepositoryPath)
        let destination = SSHCommand.shellQuote(plan.worktreePath)
        let expectedLineageID = SSHCommand.shellQuote(plan.expectedLineageID)
        let tombstoneMarker = SSHCommand.shellQuote(Self.staleRegistrationTombstoneMarker)
        let originalNameMarker = SSHCommand.shellQuote(Self.staleRegistrationOriginalNameMarker)
        return """
        repo=\(repo); target=\(destination); expected=\(expectedLineageID); marker_name=\(tombstoneMarker); original_name_marker=\(originalNameMarker); common=$(git -C "$repo" rev-parse --git-common-dir) || exit $?; case "$common" in /*) ;; *) common="$repo/$common" ;; esac; found=; for admin in "$common"/alas-stale-worktree-tombstones/*; do [ -d "$admin" ] || continue; [ -f "$admin/gitdir" ] || continue; IFS= read -r gitdir < "$admin/gitdir" || continue; [ "$gitdir" = "$target/.git" ] || continue; [ -z "$found" ] || exit 11; found="$admin"; done; [ -n "$found" ] || exit 0; base=${found##*/}; case "$base" in *.alas-removing-*) ;; *) exit 0 ;; esac; marker="$found/$marker_name"; [ -s "$marker" ] || exit 0; IFS= read -r tombstone_lineage < "$marker" || exit 13; [ "$tombstone_lineage" = "$expected" ] || exit 13; f="$found/alas-worktree-lineage"; [ -s "$f" ] || exit 13; IFS= read -r lineage < "$f" || exit 13; [ "$lineage" = "$expected" ] || exit 13; original_marker="$found/$original_name_marker"; [ -s "$original_marker" ] || exit 13; IFS= read -r restored_base < "$original_marker" || exit 13; case "$restored_base" in ""|*/*) exit 13 ;; esac; parent="$common/worktrees"; restored="$parent/$restored_base"; [ ! -e "$restored" ] || exit 13; mv "$found" "$restored" || exit $?; rm -f -- "$restored/$marker_name" "$restored/$original_name_marker"; rmdir "$common/alas-stale-worktree-tombstones" 2>/dev/null || true
        """
    }

    private static func porcelainContainsWorktree(_ porcelain: String, path: String) -> Bool {
        porcelainWorktreeEntry(porcelain, path: path) != nil
    }

    private static func porcelainWorktreeIsLocked(_ porcelain: String, path: String) -> Bool {
        porcelainWorktreeEntry(porcelain, path: path)?.contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }) == true
    }

    private static func porcelainWorktreeEntry(_ porcelain: String, path: String) -> [Substring]? {
        var current: [Substring] = []
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                if current.first == "worktree \(path)" { return current }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        return current.first == "worktree \(path)" ? current : nil
    }

    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool, forceTwice: Bool) async throws {
        switch plan.executionLocation.normalized {
        case .local:
            let path = URL(fileURLWithPath: plan.worktreePath)
            let worktree = Worktree(
                id: Worktree.makeId(path: path), projectId: plan.projectID, name: plan.branch,
                branch: plan.branch, path: path, status: .clean, lastActivity: .distantPast,
                lineageID: plan.expectedLineageID
            )
            try await WorktreeService().remove(
                repoPath: URL(fileURLWithPath: plan.sourceRepositoryPath),
                worktree: worktree,
                deleteBranchIfMerged: false,
                force: force,
                forceTwice: forceTwice,
                usesRemoteHostRegistry: false
            )
        case .ssh(let host):
            let forceFlag = force ? " -f -f" : ""
            let command = "git -C \(SSHCommand.shellQuote(plan.sourceRepositoryPath)) worktree remove\(forceFlag) -- \(SSHCommand.shellQuote(plan.worktreePath))"
            let result = try await remote.run(host: host, command: command)
            guard result.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(result.stderr) }
        }
    }

    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool {
        guard let branchCommit = plan.branchCommit, !branchCommit.isEmpty else { return false }
        switch plan.executionLocation.normalized {
        case .local:
            let repo = URL(fileURLWithPath: plan.sourceRepositoryPath)
            let branchRef = "refs/heads/\(plan.branch)"
            let ref = try await Process.git(
                ["rev-parse", "--verify", "\(branchRef)^{commit}"],
                cwd: repo,
                usesRemoteHostRegistry: false
            )
            guard ref.exitCode == 0,
                  ref.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == branchCommit
            else { return false }
            let merged = try await Process.git(["merge-base", "--is-ancestor", branchCommit, "HEAD"], cwd: repo, usesRemoteHostRegistry: false)
            guard merged.exitCode == 0 else { return false }
            let checkedOut = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
            guard checkedOut.exitCode == 0,
                  !checkedOut.stdout.split(separator: "\n").contains(where: { $0 == "branch \(branchRef)" })
            else { return false }
            let result = try await Process.git(["update-ref", "-d", branchRef, branchCommit], cwd: repo, usesRemoteHostRegistry: false)
            guard result.exitCode == 0 else { return false }
            let recheckedOut = try await Process.git(["worktree", "list", "--porcelain"], cwd: repo, usesRemoteHostRegistry: false)
            guard recheckedOut.exitCode == 0 else {
                try await Self.restoreBranch(branchRef, at: branchCommit, repo: repo)
                return false
            }
            guard !recheckedOut.stdout.split(separator: "\n").contains(where: { $0 == "branch \(branchRef)" }) else {
                try await Self.restoreBranch(branchRef, at: branchCommit, repo: repo)
                return false
            }
            return true
        case .ssh(let host):
            let repo = SSHCommand.shellQuote(plan.sourceRepositoryPath)
            let branchRef = "refs/heads/\(plan.branch)"
            let branch = SSHCommand.shellQuote(branchRef)
            let expected = SSHCommand.shellQuote(branchCommit)
            let verify = "test \"$(git -C \(repo) rev-parse --verify \(branch)^{commit})\" = \(expected)"
            let verified = try await remote.run(host: host, command: verify)
            guard verified.exitCode == 0 else { return false }
            let merged = try await remote.run(host: host, command: "git -C \(repo) merge-base --is-ancestor \(expected) HEAD")
            guard merged.exitCode == 0 else { return false }
            let initialUsage = try await remote.run(host: host, command: "git -C \(repo) worktree list --porcelain")
            guard initialUsage.exitCode == 0,
                  !initialUsage.stdout.split(separator: "\n").contains(where: { $0 == "branch \(branchRef)" })
            else { return false }
            let deleted = try await remote.run(host: host, command: "git -C \(repo) update-ref -d \(branch) \(expected)")
            guard deleted.exitCode == 0 else { return false }
            let recheckedUsage = try await remote.run(host: host, command: "git -C \(repo) worktree list --porcelain")
            guard recheckedUsage.exitCode == 0,
                  !recheckedUsage.stdout.split(separator: "\n").contains(where: { $0 == "branch \(branchRef)" })
            else {
                try await restoreRemoteBranch(branchRef, at: branchCommit, repo: repo, host: host)
                return false
            }
            return true
        }
    }

    private static func restoreBranch(_ branchRef: String, at commit: String, repo: URL) async throws {
        let objectFormat = try? await Process.git(["rev-parse", "--show-object-format"], cwd: repo, usesRemoteHostRegistry: false)
        let nullObjectID = nullObjectID(
            objectFormat: objectFormat?.exitCode == 0 ? objectFormat?.stdout : nil,
            fallbackCommit: commit
        )
        let restored = try await Process.git(["update-ref", branchRef, commit, nullObjectID], cwd: repo, usesRemoteHostRegistry: false)
        guard restored.exitCode == 0 else {
            let existing = try await Process.git(["rev-parse", "--verify", "\(branchRef)^{commit}"], cwd: repo, usesRemoteHostRegistry: false)
            guard existing.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(restored.stderr) }
            return
        }
    }

    private func restoreRemoteBranch(_ branchRef: String, at commit: String, repo: String, host: String) async throws {
        let branch = SSHCommand.shellQuote(branchRef)
        let expected = SSHCommand.shellQuote(commit)
        let objectFormat = try? await remote.run(host: host, command: "git -C \(repo) rev-parse --show-object-format")
        let nullObjectID = Self.nullObjectID(
            objectFormat: objectFormat?.exitCode == 0 ? objectFormat?.stdout : nil,
            fallbackCommit: commit
        )
        let restored = try await remote.run(host: host, command: "git -C \(repo) update-ref \(branch) \(expected) \(nullObjectID)")
        guard restored.exitCode == 0 else {
            let existing = try await remote.run(host: host, command: "git -C \(repo) rev-parse --verify \(branch)^{commit}")
            guard existing.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(restored.stderr) }
            return
        }
    }

    private static func nullObjectID(objectFormat: String?, fallbackCommit: String) -> String {
        switch objectFormat?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "sha256": return String(repeating: "0", count: 64)
        case "sha1": return String(repeating: "0", count: 40)
        default: return String(repeating: "0", count: fallbackCommit.count)
        }
    }

    func removeCheckoutRootArtifacts(for checkout: WorkspaceCheckout) async throws {
        switch checkout.executionLocation.normalized {
        case .local:
            let rootURL = URL(fileURLWithPath: checkout.rootPath)
            let manifestURL = rootURL.appendingPathComponent(WorkspaceCheckoutManifest.fileName)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(WorkspaceCheckoutManifest.self, from: data)
                guard manifest.checkoutID == checkout.id,
                      URL(fileURLWithPath: manifest.rootPath).standardizedFileURL.path == URL(fileURLWithPath: checkout.rootPath).standardizedFileURL.path
                else {
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                }
                try FileManager.default.removeItem(at: manifestURL)
            }
            if ((try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []).isEmpty {
                try? FileManager.default.removeItem(at: rootURL)
            }
        case .ssh(let host):
            let root = SSHCommand.shellQuote(checkout.rootPath)
            let manifest = SSHCommand.shellQuote(URL(fileURLWithPath: checkout.rootPath).appendingPathComponent(WorkspaceCheckoutManifest.fileName).path)
            let expectedCheckoutID = SSHCommand.shellQuote("\"checkoutID\":\"\(checkout.id.uuidString)\"")
            let expectedRootPath = SSHCommand.shellQuote(WorkspaceCheckoutManifest.jsonStringNeedle(key: "rootPath", value: checkout.rootPath))
            let command = """
            if [ -e \(manifest) ]; then
              grep -F \(expectedCheckoutID) \(manifest) >/dev/null 2>&1 || exit 73
              grep -F \(expectedRootPath) \(manifest) >/dev/null 2>&1 || exit 73
              rm -f \(manifest) || exit 74
            fi
            rmdir \(root) 2>/dev/null || true
            """
            let result = try await remote.run(host: host, command: command)
            guard result.exitCode == 0 else {
                if result.exitCode == 73 {
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                }
                throw WorktreeService.WorktreeError.gitFailed(result.stderr)
            }
        }
    }

    private func remoteDeletePreflight(_ plan: WorkspaceCheckoutCleanupPlan, host: String) async throws -> WorktreeDeletePreflight {
        let quotedPath = SSHCommand.shellQuote(plan.worktreePath)
        let status = try await remote.run(host: host, command: "git -C \(quotedPath) status --porcelain=v1 --untracked-files=normal")
        guard status.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(status.stderr) }
        var reasons: Set<WorktreeDeletePreflightReason> = []
        if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reasons.insert(.dirty)
        }
        let submodules = try await remote.run(host: host, command: "git -C \(quotedPath) submodule status --recursive")
        let submoduleLocalState: SubmoduleLocalState
        let hasSubmodules = submodules.exitCode == 0 && !submodules.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSubmodules {
            reasons.insert(.containsInitializedSubmodules)
        }
        if submodules.exitCode == 0 {
            submoduleLocalState = hasSubmodules ? .unknown : .none
        } else {
            submoduleLocalState = .unknown
        }
        let registrations = try await remote.run(host: host, command: "git -C \(quotedPath) worktree list --porcelain")
        guard registrations.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(registrations.stderr) }
        if WorktreeService.porcelainMarksWorktreeLocked(registrations.stdout, worktreePath: URL(fileURLWithPath: plan.worktreePath)) {
            reasons.insert(.locked)
        }
        return .init(reasons: reasons, submoduleLocalState: submoduleLocalState)
    }

    private func remoteInspectRoot(_ plan: WorkspaceCheckoutCleanupPlan, host: String) async -> WorkspaceCheckoutCleanupRootObservation {
        var managedNames = Set(plan.managedMemberPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        managedNames.insert(WorkspaceCheckoutManifest.fileName)
        let managedList = managedNames.isEmpty ? "''" : managedNames.map(SSHCommand.shellQuote).joined(separator: " ")
        let command = """
        r=$(cd \(SSHCommand.shellQuote(plan.rootPath)) 2>/dev/null && pwd -P) || exit 2
        for p in "$r"/* "$r"/.[!.]* "$r"/..?*; do
          [ -e "$p" ] || [ -L "$p" ] || continue
          n=${p##*/}
          skip=0
          for managed in \(managedList); do [ "$n" = "$managed" ] && skip=1; done
          [ "$skip" = 1 ] || printf '%s\\n' "$n"
        done
        """
        guard let result = try? await remote.run(host: host, command: command),
              result.exitCode == 0
        else { return .init(isContained: false, leftovers: []) }
        let leftovers = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && !managedNames.contains($0) }
            .sorted()
        return .init(isContained: true, leftovers: leftovers)
    }
}
