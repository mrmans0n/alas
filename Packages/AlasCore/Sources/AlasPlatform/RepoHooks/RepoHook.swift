import Foundation
import AlasFoundation
import AlasModel

public enum RepoHookEvent: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case sessionOpen = "session-open"
    case worktreeCreate = "worktree-create"

    public var relativePath: String {
        ".alas/hooks/\(rawValue).sh"
    }

    public var title: String {
        switch self {
        case .sessionOpen: "Session open"
        case .worktreeCreate: "Worktree create"
        }
    }
}

public enum RepoHookSource: Equatable, Sendable {
    case local
    case remote(host: String)
}

public struct RepoHook: Equatable, Sendable {
    public let event: RepoHookEvent
    public let source: RepoHookSource
    public let bytes: Data
    public let text: String
    public let hash: String

    public init(event: RepoHookEvent, source: RepoHookSource, bytes: Data, text: String, hash: String) {
        self.event = event
        self.source = source
        self.bytes = bytes
        self.text = text
        self.hash = hash
    }
}

public enum RepoHookLoadResult: Equatable, Sendable {
    case missing(source: RepoHookSource)
    case empty(source: RepoHookSource)
    case loaded(RepoHook)
    case failed(source: RepoHookSource, message: String)
}

public struct RepoHookFailure: Equatable, Sendable {
    public let event: RepoHookEvent
    public let source: RepoHookSource
    public let message: String

    public init(event: RepoHookEvent, source: RepoHookSource, message: String) {
        self.event = event
        self.source = source
        self.message = message
    }
}
