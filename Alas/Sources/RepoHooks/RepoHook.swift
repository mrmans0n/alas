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

struct RepoHook: Equatable, Sendable {
    let event: RepoHookEvent
    let source: RepoHookSource
    let bytes: Data
    let text: String
    let hash: String
}

enum RepoHookLoadResult: Equatable, Sendable {
    case missing(source: RepoHookSource)
    case empty(source: RepoHookSource)
    case loaded(RepoHook)
    case failed(source: RepoHookSource, message: String)
}

struct RepoHookFailure: Equatable, Sendable {
    let event: RepoHookEvent
    let source: RepoHookSource
    let message: String
}
