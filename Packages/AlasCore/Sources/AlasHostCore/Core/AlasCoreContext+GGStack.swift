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
        let request: GGMutationRequest = switch action {
        case .sync: .sync
        case .rebase: .rebase(target: nil)
        case .continueOperation: .continueOperation
        case .abortOperation: .abortOperation
        }
        switch action {
        case .sync, .rebase:
            let read = await ggStackRead(of: worktree, refresh: false)
            guard read.stack?.name == stackName else {
                throw HostError.failed(message: "The stack changed on the host. Review it and try again.")
            }
        case .continueOperation, .abortOperation:
            guard Self.ggOperationPaused(worktree) else {
                throw HostError.failed(message: "No gg operation is paused on the host.")
            }
        }
        let response = await serializedPublish(worktreeID: worktree.id) {
            // Checked again once it is this action's turn: work that ran
            // before it can have changed the stack, and the coordinator then
            // refuses any other than this one.
            var expected: GGStackIdentity?
            if action == .sync || action == .rebase {
                let localOnly = GGAvailability.shared.capabilities.localStackSnapshot
                let snapshot = try await GGService().currentStackSnapshot(worktreePath: worktree.path.path, refreshRemote: !localOnly)
                guard let identity = snapshot.identity, identity.stackName == stackName else {
                    throw GGMutationError.staleConfirmation
                }
                expected = identity
            }
            let state = GGStackActionState()
            try await self.runShepherdGGMutation(request, confirmedAgainst: expected, worktreeID: worktree.id, actionState: state)
            if action == .sync, state.syncHasTerminalFailure {
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
