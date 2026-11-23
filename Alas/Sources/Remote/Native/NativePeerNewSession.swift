import AlasRemoteKit
import Foundation

typealias NativePeerNewSession = RemoteNewSession

extension RemoteNewSession {
    func availableAgents(worktreeId: String?, createsWorktree: Bool) -> [RemoteAgentOption] {
        let launchProjectId = createsWorktree || fixedWorktreeId != nil
            ? projectId
            : worktrees?.first { $0.id == worktreeId }?.projectId
        return Self.agents(agents ?? [], projectId: launchProjectId)
    }

    /// Nil while the name is empty, so an untouched field shows no error;
    /// the disabled Create button already says it is required.
    static func branchValidationMessage(_ branch: String) -> String? {
        guard !branch.isEmpty else { return nil }
        if case .invalid(let message) = GitNameValidator.validateBranchName(branch) { return message }
        return nil
    }

    /// The peer refuses a base it does not list, and an invalid branch name.
    static func canCreateWorktree(base: String, branch: String, branches: Branches?) -> Bool {
        guard case .loaded(let names, _) = branches, names.contains(base) else { return false }
        return GitNameValidator.validateBranchName(branch) == .valid
    }
}
