import Foundation
import AlasFoundation
import AlasModel

public enum SearchScope: String, CaseIterable, Sendable {
    case thisWorktree
    case workspaceCheckout
    case allRepos

    public var displayName: String {
        switch self {
        case .thisWorktree: return "This worktree"
        case .workspaceCheckout: return "Workspace Checkout"
        case .allRepos:     return "All repos"
        }
    }
}
