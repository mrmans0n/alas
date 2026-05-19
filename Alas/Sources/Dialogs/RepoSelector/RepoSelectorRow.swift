import Foundation

/// All row variants the repo selector can emit. `indices` carries
/// fuzzy-match positions (matching `FuzzyMatch.Result.indices`) for
/// highlighting; empty when no query is active.
enum RepoSelectorRow: Equatable {
    case repo(ProjectConfig, indices: [Int])
    case worktree(Worktree, indices: [Int])
    case action(Action)
    case emptyHint(EmptyHint)
    case divider(label: String)

    enum Action: Equatable {
        case newProject
        case newWorktreeForRepo(projectId: String)
    }

    enum EmptyHint: Equatable {
        /// Step 1 hit Return on a project that has no visible worktrees.
        case noVisibleWorktrees(projectId: String)
        /// Step 1 with zero configured projects at all.
        case noProjects
    }

    /// True when keyboard navigation should be able to land on this row.
    var isSelectable: Bool {
        switch self {
        case .divider: return false
        default: return true
        }
    }
}
