import Foundation

/// The smallest mutation surface required to execute a frozen checkout plan.
/// It intentionally does not expose the general Git or Worktree services.
protocol WorkspaceGitOperating: Sendable {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String?
    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String?
}

extension WorkspaceGitOperating {
    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? { nil }
}

protocol WorkspaceScriptRunning: Sendable {
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws
}

/// Checkout-owned processes are deliberately separate from repository focus.
/// The concrete owner-aware implementation lands with shared Terminal/ACP
/// storage; this seam already makes archive a durable lifecycle operation.
protocol WorkspaceCheckoutSessionStopping: Sendable {
    func stopSessions(for checkoutID: UUID) async
}

/// Bridges checkout lifecycle orchestration to AppState without letting the
/// coordinator learn about focus or SwiftUI. Callers intentionally provide
/// the complete snapshot so the location-qualified owner is preserved.
struct WorkspaceCheckoutSessionStopper: WorkspaceCheckoutSessionStopping {
    let store: WorkspaceStore
    let stop: @MainActor @Sendable (WorkspaceCheckout) -> Void

    func stopSessions(for checkoutID: UUID) async {
        guard let checkout = await store.checkout(id: checkoutID) else { return }
        await stop(checkout)
    }
}

protocol WorkspaceCheckoutLifecycleOperating: Sendable {
    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight
    func inspectRoot(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutCleanupRootObservation
    func verifyCleanup(_ plan: WorkspaceCheckoutCleanupPlan) async -> WorkspaceCheckoutMemberObservation
    /// Removes only the worktree. Branch deletion is intentionally disabled.
    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool) async throws
    /// Attempts a normal merged-only branch deletion for an attempt-created
    /// branch. `false` means it was retained (for example, unmerged).
    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool
}

struct NoopWorkspaceCheckoutSessionStopper: WorkspaceCheckoutSessionStopping {
    func stopSessions(for checkoutID: UUID) async {}
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
    private var creationTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingCreationPlans: [UUID: (WorkspaceCheckout, FrozenWorkspaceCheckoutPlan)] = [:]
    private var activeArchives = Set<UUID>()
    private var activeRepairs = Set<UUID>()
    private var activeSetups = Set<String>()

    init(
        store: WorkspaceStore,
        git: any WorkspaceGitOperating = WorkspaceFrozenGitOperator(),
        scripts: any WorkspaceScriptRunning = WorkspaceSetupScriptRunner(),
        projectMutationGate: ProjectMutationGate = .shared,
        sessions: any WorkspaceCheckoutSessionStopping = NoopWorkspaceCheckoutSessionStopper(),
        lifecycle: any WorkspaceCheckoutLifecycleOperating = WorkspaceCheckoutLifecycleOperator(),
        manifests: (any WorkspaceCheckoutManifestWriting)? = nil
    ) {
        self.store = store
        self.git = git
        self.scripts = scripts
        self.projectMutationGate = projectMutationGate
        self.sessions = sessions
        self.lifecycle = lifecycle
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
        defer { activeArchives.remove(checkoutID) }
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
        await sessions.stopSessions(for: checkoutID)
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
        guard checkout.operation == .idle else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard let member = checkout.members.first(where: { $0.id == memberID }),
              let plan = makeCleanupPlan(checkout: checkout, member: member)
        else { throw WorkspaceCheckoutCoordinatorError.cleanupUnavailable }
        switch await lifecycle.verifyCleanup(plan) {
        case .exactLineage(let lineage) where lineage == plan.expectedLineageID:
            break
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
    func deleteMember(checkoutID: UUID, memberID: UUID, confirmingRisks: Bool = false) async throws -> WorkspaceCheckout {
        let checkout = try await checkout(id: checkoutID)
        guard checkout.operation == .idle || checkout.operation == .deleting else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        guard let member = checkout.members.first(where: { $0.id == memberID }),
              let cleanupPlan = member.cleanup?.plan ?? makeCleanupPlan(checkout: checkout, member: member)
        else { throw WorkspaceCheckoutCoordinatorError.cleanupUnavailable }
        // Claim and durably freeze the cleanup operation before the first
        // await. A retry retains its original plan/checkpoints verbatim.
        try await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  state.checkouts[index].operation == .idle || state.checkouts[index].operation == .deleting,
                  let memberIndex = state.checkouts[index].members.firstIndex(where: { $0.id == memberID })
            else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
            if state.checkouts[index].operation == .deleting,
               state.checkouts[index].members[memberIndex].cleanup == nil {
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
                worktreeAlreadyRemoved = true
                try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                    $0.cleanup?.worktreeRemoved = true
                    $0.cleanup?.checkpoint = .worktreeRemoved
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
                try await projectMutationGate.withMutation(projectID: member.projectID) {
                    try await lifecycle.removeWorktree(plan, force: confirmingRisks)
                }
                try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                    $0.cleanup?.worktreeRemoved = true
                    $0.cleanup?.checkpoint = .worktreeRemoved
                }
            }
            if plan.branchOwnership == .created {
                let removed = try await projectMutationGate.withMutation(projectID: member.projectID) {
                    try await lifecycle.deleteMergedBranch(plan)
                }
                try await mutateMember(checkoutID: checkoutID, memberID: memberID) {
                    $0.cleanup?.branchRemoved = removed
                    $0.cleanup?.checkpoint = removed ? .complete : .branchDeleteAttempted
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
                current.operation = .idle
                current.stopAfterCurrentOperations = false
            }
        } catch {
            try? await mutateCheckout(checkoutID) { current in
                current.operation = .idle
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
        guard let member = checkout.members.first(where: { $0.id == memberID }) else {
            throw WorkspaceCheckoutCoordinatorError.checkoutMissing
        }
        let cleanupPlan = member.cleanup?.plan ?? makeCleanupPlan(checkout: checkout, member: member)
        do {
            try await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                      state.checkouts[checkoutIndex].operation == .idle,
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
                else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
                guard state.checkouts[checkoutIndex].members[memberIndex].availability == .identityConflict else {
                    throw WorkspaceCheckoutCoordinatorError.cleanupIdentityConflict
                }
                state.checkouts[checkoutIndex].members[memberIndex].availability = .explicitlyDeleted
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .planPersisted
                state.checkouts[checkoutIndex].members[memberIndex].gitLineageID = nil
                state.checkouts[checkoutIndex].members[memberIndex].cleanupOwnership = .init()
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
        return try await self.checkout(id: checkoutID)
    }

    /// Runs member cleanup in snapshot order. A request to stop is honored at
    /// the next member boundary; failed members remain independently visible.
    func deleteCheckout(checkoutID: UUID) async throws -> WorkspaceCheckout {
        let initial = try await checkout(id: checkoutID)
        for member in initial.members where member.availability != .explicitlyDeleted {
            let current = try await checkout(id: checkoutID)
            if current.stopAfterCurrentOperations { break }
            do {
                _ = try await deleteMember(checkoutID: checkoutID, memberID: member.id)
            } catch {
                // One member's risk, failure, or conflict must not erase the
                // independent cleanup opportunity for later members.
                continue
            }
        }
        return try await checkout(id: checkoutID)
    }

    /// Forgetting is distinct from deletion: callers may discard a record only
    /// after each attempt-owned worktree has been removed. Branches retained
    /// because they are unmerged deliberately remain user artifacts.
    /// Requires a separate, explicit acknowledgement before dropping a record
    /// whose attempt-created branch was retained because it was unmerged.
    func forget(checkoutID: UUID, confirmedPreserveArtifacts: Bool = false) async throws {
        let checkout = try await self.checkout(id: checkoutID)
        guard checkout.operation == .idle,
              checkout.members.allSatisfy({ member in
                  guard let cleanup = member.cleanup,
                        cleanup.worktreeRemoved,
                        cleanup.sharedRootLeftovers.isEmpty || confirmedPreserveArtifacts
                  else { return false }
                  return cleanup.plan.branchOwnership != .created || cleanup.branchRemoved || confirmedPreserveArtifacts
              })
        else { throw WorkspaceCheckoutCoordinatorError.cleanupIncomplete }
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

    func awaitCreationCompletion(checkoutID: UUID) async {
        await creationTasks[checkoutID]?.value
    }

    private func finishCreationTask(_ checkoutID: UUID) { creationTasks[checkoutID] = nil }

    /// Explicitly retries a persisted setup checkpoint. Git creation is not
    /// part of this command, so a relaunch cannot recreate a verified member.
    func retrySetup(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
        let setupKey = setupKey(checkoutID: checkoutID, memberID: memberID)
        guard !activeSetups.contains(setupKey) else {
            throw WorkspaceCheckoutCoordinatorError.operationInProgress
        }
        activeSetups.insert(setupKey)
        defer { activeSetups.remove(setupKey) }
        let checkout = try await self.checkout(id: checkoutID)
        guard checkout.members.contains(where: { $0.id == memberID }) else {
            throw WorkspaceCheckoutCoordinatorError.checkoutMissing
        }
        let claimed = try await store.mutate { state -> WorkspaceCheckoutMember? in
            guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == memberID })
            else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
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
        return try await self.checkout(id: checkoutID)
    }

    /// Explicitly resumes Git creation from the durable frozen plan. Members
    /// that already reached worktree creation, setup success, or an identity
    /// conflict are deliberately excluded.
    func resumeCreation(checkoutID: UUID) async throws -> WorkspaceCheckout {
        guard creationTasks[checkoutID] == nil,
              !activeRepairs.contains(checkoutID)
        else { throw WorkspaceCheckoutCoordinatorError.operationInProgress }
        activeRepairs.insert(checkoutID)
        defer { activeRepairs.remove(checkoutID) }
        let checkout = try await self.checkout(id: checkoutID)
        let started = try await store.mutate { state -> Bool in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }) else {
                throw WorkspaceCheckoutCoordinatorError.checkoutMissing
            }
            guard state.checkouts[index].operation == .idle || state.checkouts[index].operation == .creating || state.checkouts[index].operation == .repairing else {
                throw WorkspaceCheckoutCoordinatorError.operationInProgress
            }
            state.checkouts[index].operation = .repairing
            state.checkouts[index].stopAfterCurrentOperations = false
            return true
        }
        guard started else { return checkout }
        for member in checkout.members {
            if await shouldStopAfterCurrentOperations(checkoutID: checkoutID) { break }
            guard member.availability != .identityConflict,
                  member.checkpoint != .worktreeCreated,
                  member.checkpoint != .setupComplete,
                  !(member.checkpoint == .failed && member.cleanupOwnership.worktreeCreated),
                  let plan = member.plan,
                  plan.checkoutMemberID == member.id,
                  plan.projectID == member.projectID,
                  plan.destinationPath == member.worktreePath,
                  !plan.sourceRepositoryPath.isEmpty,
                  !plan.baseReference.isEmpty,
                  !plan.baseCommit.isEmpty
            else { continue }
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
                    return .worktreeCreating
                case .setupRunning:
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .setupRunning
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    return .setupRunning
                case .failed where !current.cleanupOwnership.worktreeCreated:
                    let checkpoint: WorkspaceCheckoutCheckpoint = current.cleanupOwnership.branchOwnership == .unknown ? .branchPreparing : .worktreeCreating
                    state.checkouts[checkoutIndex].members[memberIndex].checkpoint = checkpoint
                    state.checkouts[checkoutIndex].members[memberIndex].availability = .pending
                    state.checkouts[checkoutIndex].members[memberIndex].cleanup = nil
                    return checkpoint
                default:
                    return nil
                }
            }
            guard let claimedCheckpoint else { continue }
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
            if claimedCheckpoint == .setupRunning {
                await runSetup(member: frozenMember, checkout: checkout)
            } else if claimedCheckpoint == .worktreeCreating {
                let operation = WorkspaceFrozenWorktreeOperation(
                    checkoutID: checkout.id,
                    checkoutMemberID: plan.checkoutMemberID,
                    projectID: plan.projectID,
                    executionLocation: checkout.executionLocation,
                    sourceRepositoryPath: plan.sourceRepositoryPath,
                    destinationPath: plan.destinationPath,
                    branch: checkout.branch,
                    baseCommit: plan.baseCommit,
                    branchIntent: .init(plan.branchIntent, baseCommit: plan.baseCommit)
                )
                do {
                    if let lineageID = try await git.existingCreatedWorktreeLineage(operation) {
                        try await updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { current in
                            current.checkpoint = .worktreeCreated
                            current.gitLineageID = lineageID
                            current.cleanupOwnership = .init(
                                worktreeCreated: true,
                                branchOwnership: plan.branchIntent == .reuse ? .reused : .created
                            )
                        }
                        await runSetup(member: frozenMember, checkout: checkout)
                    } else {
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
                }
            } else {
                await execute(member: frozenMember, checkout: checkout)
            }
        }
        await finishIfAllMembersTerminal(checkoutID: checkoutID, owning: .repairing)
        return try await self.checkout(id: checkoutID)
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
        let workspaceMembers = Dictionary(uniqueKeysWithValues: workspace.members.map { ($0.id, $0) })
        guard workspaceMembers.count == workspace.members.count,
              Set(plan.members.map(\.workspaceMemberID)).count == plan.members.count,
              Set(plan.members.map(\.checkoutMemberID)).count == plan.members.count
        else { throw WorkspaceCheckoutCoordinatorError.incompletePlan }
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

            for _ in 0 ..< min(4, pending.count) {
                guard scheduleNextAvailable() else { break }
            }

            while let projectID = await group.next() {
                activeProjectIDs.remove(projectID)
                guard !(await shouldStopAfterCurrentOperations(checkoutID: checkout.id)) else { continue }
                while activeProjectIDs.count < 4, scheduleNextAvailable() {}
            }
        }
        await finishIfAllMembersTerminal(checkoutID: checkout.id, owning: .creating)
    }

    private func execute(member plan: FrozenWorkspaceCheckoutPlan.Member, checkout: WorkspaceCheckout) async {
        let operation = WorkspaceFrozenWorktreeOperation(
            checkoutID: checkout.id,
            checkoutMemberID: plan.checkoutMemberID,
            projectID: plan.projectID,
            executionLocation: checkout.executionLocation,
            sourceRepositoryPath: plan.sourceRepositoryPath,
            destinationPath: plan.destinationPath,
            branch: checkout.branch,
            baseCommit: plan.baseCommit,
            branchIntent: .init(plan.branchIntent, baseCommit: plan.baseCommit)
        )
        do {
            try await projectMutationGate.withMutation(projectID: plan.projectID) {
                if await self.shouldPrepareBranch(checkoutID: checkout.id, memberID: plan.checkoutMemberID) {
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        member.checkpoint = .branchPreparing
                    }
                    try await self.git.prepareBranch(operation)
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        member.checkpoint = .branchPrepared
                        member.cleanupOwnership.branchOwnership = plan.branchIntent == .reuse ? .reused : .created
                    }
                    try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                        member.checkpoint = .worktreeCreating
                    }
                }
                let existingLineageID = try await self.git.existingCreatedWorktreeLineage(operation)
                let lineageID = if let existingLineageID {
                    existingLineageID
                } else {
                    try await self.git.createWorktree(operation)
                }
                try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                    member.checkpoint = .worktreeCreated
                    member.gitLineageID = lineageID
                    member.cleanup = nil
                    member.cleanupOwnership = .init(
                        worktreeCreated: true,
                        branchOwnership: plan.branchIntent == .reuse ? .reused : .created
                    )
                }
            }
            try await runSetupThrowing(member: plan, checkout: checkout)
        } catch {
            try? await store.mutate { state in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkout.id }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == plan.checkoutMemberID })
                else { throw WorkspaceCheckoutCoordinatorError.checkoutMissing }
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .failed
                state.checkouts[checkoutIndex].members[memberIndex].availability = .unavailable
                state.checkouts[checkoutIndex].diagnostics.append(.init(severity: .error, message: "Workspace creation failed for \(state.checkouts[checkoutIndex].members[memberIndex].fallbackProjectName)."))
            }
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

    private func setupScript(checkoutID: UUID, memberID: UUID) async -> String {
        guard case .loaded(let state) = await store.load(),
              let checkout = state.checkouts.first(where: { $0.id == checkoutID }),
              let member = checkout.members.first(where: { $0.id == memberID })
        else { return "" }
        let shared = checkout.configurationSnapshot?.shared.worktreeCreateScript ?? ""
        let memberScript = checkout.configurationSnapshot?.members[member.workspaceMemberID]?.setupScript ?? ""
        return [shared, memberScript].filter { !$0.isEmpty }.joined(separator: "\n")
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
        } catch WorkspaceStoreError.recoveryRequired {
            throw WorkspaceCheckoutCoordinatorError.workspaceStateUnavailable
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
            rootPath: checkout.rootPath,
            managedMemberPaths: checkout.members.map(\.worktreePath),
            worktreePath: plan.destinationPath,
            branch: checkout.branch,
            expectedLineageID: lineage,
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
}

struct WorkspaceFrozenGitOperator: WorkspaceGitOperating {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws {
        try await WorktreeService().prepareFrozenBranch(
            repoPath: URL(fileURLWithPath: operation.sourceRepositoryPath),
            branch: operation.branch,
            intent: operation.branchIntent
        )
    }

    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        let worktree = try await WorktreeService().addFrozen(
            repoPath: URL(fileURLWithPath: operation.sourceRepositoryPath),
            branch: operation.branch,
            destination: URL(fileURLWithPath: operation.destinationPath),
            projectId: operation.projectID,
            intent: operation.branchIntent
        )
        return worktree.lineageID
    }

    func existingCreatedWorktreeLineage(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String? {
        switch operation.executionLocation.normalized {
        case .local:
            let destination = URL(fileURLWithPath: operation.destinationPath)
            guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
            let head = try await Process.git(["rev-parse", "--verify", "HEAD^{commit}"], cwd: destination)
            guard head.exitCode == 0,
                  head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operation.baseCommit
            else { return nil }
            let branch = try await Process.git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: destination)
            guard branch.exitCode == 0,
                  branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operation.branch
            else { return nil }
            return WorktreeService.localLineageID(forWorktreeAt: destination)
        case .ssh(let host):
            let path = SSHCommand.shellQuote(operation.destinationPath)
            let branch = SSHCommand.shellQuote(operation.branch)
            let commit = SSHCommand.shellQuote(operation.baseCommit)
            let command = "p=\(path); b=\(branch); c=\(commit); test -d \"$p\" || exit 2; [ \"$(git -C \"$p\" rev-parse --verify HEAD^{commit})\" = \"$c\" ] || exit 3; [ \"$(git -C \"$p\" rev-parse --abbrev-ref HEAD)\" = \"$b\" ] || exit 4; \(WorktreeService.remoteLineageIDCommand(path: operation.destinationPath))"
            let result = try await WorkspaceRemoteTransport().run(host: host, command: command)
            guard result.exitCode == 0 else { return nil }
            return WorktreeService.normalizedLineageID(result.stdout)
        }
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

    init(remote: WorkspaceRemoteTransport = .init()) {
        self.remote = remote
    }

    func deletePreflight(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> WorktreeDeletePreflight {
        switch plan.executionLocation.normalized {
        case .local:
            return try await WorktreeService().deletePreflight(worktreePath: URL(fileURLWithPath: plan.worktreePath))
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
            let managedNames = Set(plan.managedMemberPaths.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.lastPathComponent
            })
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
                .filter { !managedNames.contains($0) } ?? []
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

    func removeWorktree(_ plan: WorkspaceCheckoutCleanupPlan, force: Bool) async throws {
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
                force: force
            )
        case .ssh(let host):
            let forceFlag = force ? " -f" : ""
            let command = "git -C \(SSHCommand.shellQuote(plan.sourceRepositoryPath)) worktree remove\(forceFlag) -- \(SSHCommand.shellQuote(plan.worktreePath))"
            let result = try await remote.run(host: host, command: command)
            guard result.exitCode == 0 else { throw WorktreeService.WorktreeError.gitFailed(result.stderr) }
        }
    }

    func deleteMergedBranch(_ plan: WorkspaceCheckoutCleanupPlan) async throws -> Bool {
        switch plan.executionLocation.normalized {
        case .local:
            let result = try await Process.git(["branch", "-d", plan.branch], cwd: URL(fileURLWithPath: plan.sourceRepositoryPath))
            return result.exitCode == 0
        case .ssh(let host):
            let command = "git -C \(SSHCommand.shellQuote(plan.sourceRepositoryPath)) branch -d -- \(SSHCommand.shellQuote(plan.branch))"
            let result = try await remote.run(host: host, command: command)
            return result.exitCode == 0
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
        let hasSubmodules = submodules.exitCode == 0 && !submodules.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasSubmodules {
            reasons.insert(.containsInitializedSubmodules)
        }
        return .init(reasons: reasons, submoduleLocalState: hasSubmodules ? .unknown : .none)
    }

    private func remoteInspectRoot(_ plan: WorkspaceCheckoutCleanupPlan, host: String) async -> WorkspaceCheckoutCleanupRootObservation {
        let managedNames = Set(plan.managedMemberPaths.map { URL(fileURLWithPath: $0).lastPathComponent })
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
        let leftovers = result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .init(isContained: true, leftovers: leftovers)
    }
}
