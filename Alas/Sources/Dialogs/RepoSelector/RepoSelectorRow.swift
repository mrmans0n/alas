import Foundation

/// All row variants the repo selector can emit. `indices` carries
/// fuzzy-match positions (matching `FuzzyMatch.Result.indices`) for
/// highlighting; empty when no query is active.
enum RepoSelectorRow: Equatable {
    case worktree(Worktree, indices: [Int], isCurrent: Bool)
    case action(Action)
    case emptyHint(EmptyHint)
    case recentHeader
    case projectHeader(projectId: String)
    case actionsHeader

    enum Action: Equatable {
        case newProject
        case newWorktreeForRepo(projectId: String)
    }

    enum EmptyHint: Equatable {
        /// Zero configured projects.
        case noProjects
    }

    /// True when keyboard navigation should be able to land on this row.
    var isSelectable: Bool {
        switch self {
        case .recentHeader, .projectHeader, .actionsHeader: return false
        default: return true
        }
    }
}
