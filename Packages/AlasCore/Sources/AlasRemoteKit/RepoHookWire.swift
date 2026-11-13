import Foundation

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
}
