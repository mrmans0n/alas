import Foundation

/// The "new session on a peer" sheet's state. `worktrees`, `agents` and
/// `branches` are nil until the peer answers.
public struct RemoteNewSession: Identifiable, Equatable {
    public enum Phase: Equatable {
        case editing
        case creating
        case failed(String)
    }

    /// Start the session in one of the repo's worktrees, or in a new one the
    /// peer creates from `base`.
    public enum WorktreeMode: Hashable {
        case existing
        case new
    }

    public enum Branches: Equatable {
        case loaded(names: [String], preferredBase: String)
        case failed(String)
    }

    public let id = UUID()
    public let serverId: String
    public let peerName: String
    public let projectId: String?
    public let repoName: String
    public var worktrees: [RemoteWorktreeOption]?
    public var agents: [RemoteAgentOption]?
    public var branches: Branches?
    public var phase: Phase = .editing
    /// Set when the peer created a worktree but not its session, so the
    /// sheet can retry in that worktree instead of creating another.
    public var recoveredWorktreeId: String?

    public init(serverId: String, peerName: String, projectId: String?, repoName: String) {
        self.serverId = serverId
        self.peerName = peerName
        self.projectId = projectId
        self.repoName = repoName
    }

    public var isLoading: Bool { worktrees == nil || agents == nil }

    public var branchNames: [String] {
        if case .loaded(let names, _) = branches { return names }
        return []
    }

    /// The peer's preferred base when it is one of its branches, else its
    /// first branch.
    public static func preselectedBase(in branches: Branches?) -> String? {
        guard case .loaded(let names, let preferred) = branches else { return nil }
        return names.contains(preferred) ? preferred : names.first
    }

    /// Opens on "New worktree" when the repo has no worktree to pick.
    public static func defaultWorktreeMode(for worktrees: [RemoteWorktreeOption]) -> WorktreeMode {
        worktrees.isEmpty ? .new : .existing
    }

    /// The clicked repo's worktrees, in the peer's order. Older peers send no
    /// `projectId`, so those rows match on the repo's display name instead.
    public static func worktrees(_ all: [RemoteWorktreeOption], projectId: String?, repoName: String) -> [RemoteWorktreeOption] {
        all.filter { option in
            if let projectId, let optionProjectId = option.projectId { return optionProjectId == projectId }
            return option.projectName == repoName
        }
    }

    /// The agents the host can launch in `projectId`.
    public static func agents(_ all: [RemoteAgentOption], projectId: String?) -> [RemoteAgentOption] {
        all.filter { $0.isAvailable(inProjectId: projectId) }
    }

    public static func preselectedWorktreeId(in options: [RemoteWorktreeOption], selectedWorktreeId: String?) -> String? {
        if let selectedWorktreeId, options.contains(where: { $0.id == selectedWorktreeId }) { return selectedWorktreeId }
        return options.first?.id
    }

    public static func preselectedAgentId(in agents: [RemoteAgentOption]) -> String? {
        (agents.first(where: \.isDefault) ?? agents.first)?.id
    }

    /// Which of the model and effort chips the sheet shows for an agent: only
    /// the ones the peer has a remembered list for. With neither, a hint says
    /// the agent's defaults apply. Nil until an agent is selected.
    public struct ChipVisibility: Equatable {
        public let showsModel: Bool
        public let showsEffort: Bool
        public var showsDefaultsHint: Bool { !showsModel && !showsEffort }
    }

    public static func chipVisibility(for agent: RemoteAgentOption?) -> ChipVisibility? {
        guard let agent else { return nil }
        return ChipVisibility(
            showsModel: !(agent.models ?? []).isEmpty,
            showsEffort: !(agent.efforts ?? []).isEmpty
        )
    }
}

/// Port of the web client's `isValidBranchName` (worktree-creation.js), so the
/// phone rejects what the web would before asking the host to create it.
public enum RemoteBranchName {
    public static let invalidMessage = "Enter a valid branch name."

    /// Nil when `name` is a valid branch name.
    public static func validationMessage(_ name: String) -> String? {
        isValid(name) ? nil : invalidMessage
    }

    private static func isValid(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf16.count <= 250, // JS string length counts UTF-16 units
              !scalars.contains(where: { $0 == " " || $0.value < 0x20 || $0.value == 0x7f }),
              !name.hasPrefix("/"), !name.hasSuffix("/"), !name.contains("//"),
              !name.contains("@{"), name != "@", !name.hasPrefix("-")
        else { return false }

        let forbidden = Set("~^:\\?*[")
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.enumerated().allSatisfy { index, component in
            if component.isEmpty || component.hasPrefix(".") { return false }
            if component.contains("..") || component.hasSuffix(".lock") { return false }
            if index == components.count - 1 && component.hasSuffix(".") { return false }
            return !component.contains(where: forbidden.contains)
        }
    }
}
