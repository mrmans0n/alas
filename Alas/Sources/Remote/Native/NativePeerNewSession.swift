import Foundation

/// The "new session on a peer" sheet's state. `worktrees`, `agents` and
/// `branches` are nil until the peer answers.
struct NativePeerNewSession: Identifiable, Equatable {
    enum Phase: Equatable {
        case editing
        case creating
        case failed(String)
    }

    /// Start the session in one of the repo's worktrees, or in a new one the
    /// peer creates from `base`.
    enum WorktreeMode: Hashable {
        case existing
        case new
    }

    enum Branches: Equatable {
        case loaded(names: [String], preferredBase: String)
        case failed(String)
    }

    let id = UUID()
    let serverId: String
    let peerName: String
    let projectId: String?
    let repoName: String
    var worktrees: [RemoteWorktreeOption]?
    var agents: [RemoteAgentOption]?
    var branches: Branches?
    var phase: Phase = .editing
    /// Set when the peer created a worktree but not its session, so the
    /// sheet can retry in that worktree instead of creating another.
    var recoveredWorktreeId: String?

    var isLoading: Bool { worktrees == nil || agents == nil }

    var branchNames: [String] {
        if case .loaded(let names, _) = branches { return names }
        return []
    }

    /// The peer's preferred base when it is one of its branches, else its
    /// first branch.
    static func preselectedBase(in branches: Branches?) -> String? {
        guard case .loaded(let names, let preferred) = branches else { return nil }
        return names.contains(preferred) ? preferred : names.first
    }

    /// Opens on "New worktree" when the repo has no worktree to pick.
    static func defaultWorktreeMode(for worktrees: [RemoteWorktreeOption]) -> WorktreeMode {
        worktrees.isEmpty ? .new : .existing
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

    /// The clicked repo's worktrees, in the peer's order. Older peers send no
    /// `projectId`, so those rows match on the repo's display name instead.
    static func worktrees(_ all: [RemoteWorktreeOption], projectId: String?, repoName: String) -> [RemoteWorktreeOption] {
        all.filter { option in
            if let projectId, let optionProjectId = option.projectId { return optionProjectId == projectId }
            return option.projectName == repoName
        }
    }

    static func preselectedWorktreeId(in options: [RemoteWorktreeOption], selectedWorktreeId: String?) -> String? {
        if let selectedWorktreeId, options.contains(where: { $0.id == selectedWorktreeId }) { return selectedWorktreeId }
        return options.first?.id
    }

    static func preselectedAgentId(in agents: [RemoteAgentOption]) -> String? {
        (agents.first(where: \.isDefault) ?? agents.first)?.id
    }

    /// Which of the model and effort chips the sheet shows for an agent: only
    /// the ones the peer has a remembered list for. With neither, a hint says
    /// the agent's defaults apply. Nil until an agent is selected.
    struct ChipVisibility: Equatable {
        let showsModel: Bool
        let showsEffort: Bool
        var showsDefaultsHint: Bool { !showsModel && !showsEffort }
    }

    static func chipVisibility(for agent: RemoteAgentOption?) -> ChipVisibility? {
        guard let agent else { return nil }
        return ChipVisibility(
            showsModel: !(agent.models ?? []).isEmpty,
            showsEffort: !(agent.efforts ?? []).isEmpty
        )
    }
}
