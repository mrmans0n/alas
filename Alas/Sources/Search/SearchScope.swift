import Foundation

enum SearchScope: String, CaseIterable, Sendable {
    case thisWorktree
    case workspaceCheckout
    case allRepos

    var displayName: String {
        switch self {
        case .thisWorktree: return "This worktree"
        case .workspaceCheckout: return "Workspace Checkout"
        case .allRepos:     return "All repos"
        }
    }
}
