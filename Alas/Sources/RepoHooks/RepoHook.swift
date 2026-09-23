import Foundation

enum RepoHookEvent: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case sessionOpen = "session-open"
    case worktreeCreate = "worktree-create"

    var relativePath: String {
        ".alas/hooks/\(rawValue).sh"
    }

    var title: String {
        switch self {
        case .sessionOpen: "Session open"
        case .worktreeCreate: "Worktree create"
        }
    }
}

enum RepoHookSource: Equatable, Sendable {
    case local
    case remote(host: String)
}
