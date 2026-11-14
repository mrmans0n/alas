import Foundation
import AlasModel
import AlasIntegrations

extension AlasCoreContext {
    /// `worktree`'s gg stack, for a Mac's Changes tab: what `gg ls` reports
    /// when the host's settings make it a stack, else why it shows none.
    func ggStackRead(of worktree: Worktree, refresh: Bool) async -> HostGGStackRead {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            return HostGGStackRead(stack: nil, problem: nil)
        }
        let context = ggContext(project: project, worktree: worktree)
        // The resolver checks for gg before the project's mode: a missing gg
        // is a problem only for a worktree its settings mean as a stack.
        let meantAsStack = project.host == nil && !project.isFolder && GGWorktreeContextResolver.isPolicyEnabled(
            projectMode: project.ggMode,
            worktreeOverride: projects.ggWorktreeMode(projectId: project.id, worktreeId: worktree.id),
            isMainWorktree: projects.isMain(worktree, in: project),
            repoHasGGConfig: GGStackGate.repoHasGGConfig(repoPath: project.path)
        )
        if let problem = Self.ggStackProblem(context, meantAsStack: meantAsStack) {
            return HostGGStackRead(stack: nil, problem: problem)
        }
        // A branch off the naming scheme can still be a stack; gg answers.
        guard context.permitsCurrentStackQuery else { return HostGGStackRead(stack: nil, problem: nil) }
        let isPaused = Self.ggOperationPaused(worktree)
        do {
            // Older gg builds lack `--no-refresh`; they read remote state too.
            let localOnly = !refresh && GGAvailability.shared.capabilities.localStackSnapshot
            let stack = try await GGService().currentStack(worktreePath: worktree.path.path, refreshRemote: !localOnly)
            return HostGGStackRead(stack: stack, problem: nil, isPaused: isPaused)
        } catch {
            let problem = (error as? GGServiceError)?.userMessage ?? error.localizedDescription
            return HostGGStackRead(stack: nil, problem: problem, isPaused: isPaused)
        }
    }

    /// Runs `action` on `worktree`'s stack, in turn with the host's other gg
    /// work on it. Sync and Rebase need the stack the Mac saw; Continue and
    /// Abort, a paused operation.
    func runGGStackAction(_ action: HostGGStackAction, stackName: String, in worktree: Worktree) async throws {
        switch action {
        case .sync: try await runCheckedGGStackMutation(.sync, stackName: stackName, in: worktree)
        case .rebase: try await runCheckedGGStackMutation(.rebase(target: nil), stackName: stackName, in: worktree)
        case .continueOperation, .abortOperation:
            guard Self.ggOperationPaused(worktree) else {
                throw HostError.failed(message: "No gg operation is paused on the host.")
            }
            try await runGGStackMutation(action == .continueOperation ? .continueOperation : .abortOperation,
                                         stackName: nil, in: worktree)
        }
    }

    /// Runs `request` on `worktree`'s stack only while it is still the one
    /// named `stackName`, the stack the Mac saw, and `stillHolds` accepts it.
    func runCheckedGGStackMutation(
        _ request: GGMutationRequest, stackName: String, in worktree: Worktree,
        stillHolds: @escaping @Sendable (GGStack) -> Bool = { _ in true }
    ) async throws {
        let read = await ggStackRead(of: worktree, refresh: false)
        guard let stack = read.stack, stack.name == stackName, stillHolds(stack) else {
            throw HostError.failed(message: "The stack changed on the host. Review it and try again.")
        }
        try await runGGStackMutation(request, stackName: stackName, in: worktree, stillHolds: stillHolds)
    }

    /// The ids of the entries `gg land --until through` merges, bottom
    /// first; nil when `through` is not in `stack`.
    nonisolated static func ggLandScope(through: String, in stack: GGStack) -> [String]? {
        stack.entries.first { $0.id == through }.map { GGLandReadiness.scope(upTo: $0, in: stack).map(\.id) }
    }

    private func runGGStackMutation(
        _ request: GGMutationRequest, stackName: String?, in worktree: Worktree,
        stillHolds: @escaping @Sendable (GGStack) -> Bool = { _ in true }
    ) async throws {
        let response = await serializedPublish(worktreeID: worktree.id) {
            // Checked again once it is this request's turn: work that ran
            // before it can have changed the stack, and the coordinator then
            // refuses any other than this one.
            var expected: GGStackIdentity?
            if let stackName {
                let localOnly = GGAvailability.shared.capabilities.localStackSnapshot
                let snapshot = try await GGService().currentStackSnapshot(worktreePath: worktree.path.path, refreshRemote: !localOnly)
                guard let identity = snapshot.identity, identity.stackName == stackName,
                      let stack = snapshot.stack, stillHolds(stack)
                else {
                    throw GGMutationError.staleConfirmation
                }
                expected = identity
            }
            let state = GGStackActionState()
            try await self.runShepherdGGMutation(request, confirmedAgainst: expected, worktreeID: worktree.id, actionState: state)
            if request == .sync, state.syncHasTerminalFailure {
                throw GGMutationError.syncTerminalFailure(message: state.lastError ?? "GG sync failed.")
            }
            return ""
        }
        if case .error(let message) = response { throw HostError.failed(message: message) }
    }

    /// A gg operation Alas started is paused on a conflict, as the app's
    /// stack drawer tells it.
    static func ggOperationPaused(_ worktree: Worktree) -> Bool {
        GGStackGate.operationInProgress(repoPath: worktree.path.path)
            && GGStackGate.alasGGOperationInProgress(repoPath: worktree.path.path)
    }

    /// Why a worktree the project means as a stack shows none; nil when it
    /// is one, or simply isn't meant to be.
    static func ggStackProblem(_ context: GGWorktreeContext, meantAsStack: Bool) -> String? {
        guard meantAsStack, case .inactive(let reason) = context else { return nil }
        switch reason {
        case .cliMissing: return "gg isn't installed on the host, or wasn't on its PATH when it started."
        case .branchUsernameMissing: return "gg on the host has no branch username: set defaults.branch_username in its config."
        case .masterDisabled, .remoteProject, .policyOff, .branchPrefixMismatch: return nil
        }
    }
}
