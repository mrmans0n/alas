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

/// What a paired Mac says about the repository hook of work it starts here.
public enum RepoHookConsent: Codable, Equatable, Sendable {
    /// Send the hook back for approval instead of starting the work.
    case ask
    /// Start the work without the hook.
    case skip
    /// Approve the hook whose hash is `hash`, and only that one.
    case approve(hash: String)
}

/// A repository hook as sent to a paired Mac to approve.
public struct PeerRepoHook: Codable, Equatable, Sendable {
    public let event: RepoHookEvent
    public let text: String
    public let hash: String

    public init(event: RepoHookEvent, text: String, hash: String) {
        self.event = event
        self.text = text
        self.hash = hash
    }

    public init(_ hook: RepoHook) {
        self.init(event: hook.event, text: hook.text, hash: hook.hash)
    }

    /// The hook as one read from `host`, for the approval sheet.
    public func repoHook(fromHost host: String) -> RepoHook {
        RepoHook(event: event, source: .remote(host: host), bytes: Data(text.utf8), text: text, hash: hash)
    }
}
