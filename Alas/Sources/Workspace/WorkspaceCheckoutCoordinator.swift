import Foundation

/// The smallest mutation surface required to execute a frozen checkout plan.
/// It intentionally does not expose the general Git or Worktree services.
protocol WorkspaceGitOperating: Sendable {
    func prepareBranch(_ operation: WorkspaceFrozenWorktreeOperation) async throws
    func createWorktree(_ operation: WorkspaceFrozenWorktreeOperation) async throws -> String?
}

protocol WorkspaceScriptRunning: Sendable {
    func runSetup(for operation: WorkspaceCheckoutSetupOperation) async throws
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

    init(
        store: WorkspaceStore,
        git: any WorkspaceGitOperating = WorkspaceFrozenGitOperator(),
        scripts: any WorkspaceScriptRunning = WorkspaceSetupScriptRunner(),
        projectMutationGate: ProjectMutationGate = .shared
    ) {
        self.store = store
        self.git = git
        self.scripts = scripts
        self.projectMutationGate = projectMutationGate
    }

    /// Persists the complete frozen checkout before scheduling any Git work.
    /// Individual member failures are checkpointed and never cancel siblings.
    func create(
        workspace: Workspace,
        plan: FrozenWorkspaceCheckoutPlan,
        configurationSnapshot: WorkspaceCheckoutConfigurationSnapshot? = nil
    ) async throws -> WorkspaceCheckout {
        let checkout = try await persistFrozenCheckout(
            workspace: workspace,
            plan: plan,
            configurationSnapshot: configurationSnapshot
        )
        await executeMembers(of: checkout, plan: plan)
        return try await self.checkout(id: checkout.id)
    }

    /// Explicitly retries a persisted setup checkpoint. Git creation is not
    /// part of this command, so a relaunch cannot recreate a verified member.
    func retrySetup(checkoutID: UUID, memberID: UUID) async throws -> WorkspaceCheckout {
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
                  member.checkpoint == .worktreeCreated || (member.checkpoint == .failed && member.cleanupOwnership.worktreeCreated),
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
        let operation = WorkspaceCheckoutSetupOperation(
            checkoutID: checkout.id,
            checkoutMemberID: member.id,
            executionLocation: checkout.executionLocation,
            worktreePath: member.plan!.destinationPath,
            script: await setupScript(checkoutID: checkout.id, memberID: member.id)
        )
        do {
            try await scripts.runSetup(for: operation)
            try await updateMember(checkoutID: checkout.id, memberID: member.id) {
                $0.checkpoint = .setupComplete
                $0.availability = .available
            }
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
        let checkout = try await self.checkout(id: checkoutID)
        for member in checkout.members {
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
            let claimed = (try? await store.mutate { state -> Bool in
                guard let checkoutIndex = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                      let memberIndex = state.checkouts[checkoutIndex].members.firstIndex(where: { $0.id == member.id })
                else { return false }
                let current = state.checkouts[checkoutIndex].members[memberIndex]
                guard current.id == member.id,
                      current.plan == plan,
                      current.checkpoint == .planPersisted || (current.checkpoint == .failed && !current.cleanupOwnership.worktreeCreated)
                else { return false }
                state.checkouts[checkoutIndex].members[memberIndex].checkpoint = .branchPreparing
                return true
            }) ?? false
            guard claimed else { continue }
            await execute(
                member: .init(
                    checkoutMemberID: plan.checkoutMemberID,
                    workspaceMemberID: member.workspaceMemberID,
                    projectID: plan.projectID,
                    sourceRepositoryPath: plan.sourceRepositoryPath,
                    destinationPath: plan.destinationPath,
                    baseReference: plan.baseReference,
                    baseCommit: plan.baseCommit,
                    branchIntent: plan.branchIntent
                ),
                checkout: checkout
            )
        }
        await finishIfAllMembersTerminal(checkoutID: checkoutID)
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
        await withTaskGroup(of: Void.self) { group in
            var iterator = plan.members.makeIterator()
            for _ in 0 ..< min(4, plan.members.count) {
                guard let member = iterator.next() else { break }
                group.addTask { await self.execute(member: member, checkout: checkout) }
            }
            while await group.next() != nil {
                guard let member = iterator.next() else { continue }
                group.addTask { await self.execute(member: member, checkout: checkout) }
            }
        }
        await finishIfAllMembersTerminal(checkoutID: checkout.id)
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
                let lineageID = try await self.git.createWorktree(operation)
                try await self.updateMember(checkoutID: checkout.id, memberID: plan.checkoutMemberID) { member in
                    member.checkpoint = .worktreeCreated
                    member.gitLineageID = lineageID
                    member.cleanupOwnership = .init(
                        worktreeCreated: true,
                        branchOwnership: plan.branchIntent == .reuse ? .reused : .created
                    )
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

    private func finishIfAllMembersTerminal(checkoutID: UUID) async {
        try? await store.mutate { state in
            guard let index = state.checkouts.firstIndex(where: { $0.id == checkoutID }),
                  state.checkouts[index].members.allSatisfy({ $0.checkpoint == .setupComplete || $0.checkpoint == .failed })
            else { return }
            state.checkouts[index].operation = .idle
        }
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
