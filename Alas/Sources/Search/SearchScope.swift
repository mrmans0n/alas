import Foundation

enum SearchScope: String, CaseIterable, Sendable {
    case thisWorktree
    case allRepos

    var displayName: String {
        switch self {
        case .thisWorktree: return "This worktree"
        case .allRepos:     return "All repos"
        }
    }
}
