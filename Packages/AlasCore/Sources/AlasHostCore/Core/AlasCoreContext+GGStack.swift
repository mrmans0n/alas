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
        do {
            let stack = try await GGService().currentStack(worktreePath: worktree.path.path, refreshRemote: refresh)
            return HostGGStackRead(stack: stack, problem: nil)
        } catch {
            return HostGGStackRead(stack: nil, problem: (error as? GGServiceError)?.userMessage ?? error.localizedDescription)
        }
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
