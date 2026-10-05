import Foundation

/// The "new session on a peer" sheet's state. `worktrees` and `agents` are
/// nil until the peer answers.
struct NativePeerNewSession: Identifiable, Equatable {
    enum Phase: Equatable {
        case editing
        case creating
        case failed(String)
    }

    let id = UUID()
    let serverId: String
    let peerName: String
    let projectId: String?
    let repoName: String
    var worktrees: [RemoteWorktreeOption]?
    var agents: [RemoteAgentOption]?
    var phase: Phase = .editing

    var isLoading: Bool { worktrees == nil || agents == nil }

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
}
