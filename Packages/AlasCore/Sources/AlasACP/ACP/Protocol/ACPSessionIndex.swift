import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

// The client-neutral session index of our Claude and Codex adapter forks:
// the AIR `sessionIndex` extension (bounded `session/list` with row metadata,
// linked-worktree scope, archive filter, rename, archive, and a list
// subscription), negotiated through top-level `_meta.sessionIndex` instead of
// the AIR client declaration. Alas stays a non-AIR client, so tool rendering
// and the native subagent format do not change.

/// `initialize.clientCapabilities._meta.sessionIndex`.
public struct ACPSessionIndexDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// What the agent supports, from `InitializeResponse._meta.sessionIndex`.
public struct ACPSessionIndexSupport: Equatable, Sendable {
    /// `_session/archive` and `_session/unarchive`.
    public let archive: Bool
    /// `_session/rename`.
    public let rename: Bool
    /// `_session/list/subscribe`, `_session/list/unsubscribe`, `_session/list/changes`.
    public let listSubscribe: Bool
    /// Rows carry `agentWorktree` for a worktree the agent made itself.
    public let worktrees: Bool

    public init(archive: Bool = false, rename: Bool = false, listSubscribe: Bool = false, worktrees: Bool = false) {
        self.archive = archive
        self.rename = rename
        self.listSubscribe = listSubscribe
        self.worktrees = worktrees
    }
}

/// `InitializeResponse._meta.sessionIndex`, as sent.
public struct ACPSessionIndexCapability: Codable, Equatable, Sendable {
    public let version: Int?
    public let capabilities: [String]?

    /// The only version this client speaks; another one could change the
    /// list or request shapes, so it falls back to the basic browser.
    public static let supportedVersion = 1

    /// Nil unless the advertisement is the version this client speaks.
    public var support: ACPSessionIndexSupport? {
        guard version == Self.supportedVersion else { return nil }
        let names = Set(capabilities ?? [])
        return .init(
            archive: names.contains("sessionArchive"),
            rename: names.contains("sessionRename"),
            listSubscribe: names.contains("sessionListSubscribe"),
            worktrees: names.contains("sessionWorktrees")
        )
    }
}

/// `_meta.sessionIndex.list.archived` of `session/list`.
public enum ACPSessionArchiveFilter: String, Codable, Equatable, Sendable {
    case unarchived
    case archived
    case all
}

/// `_meta.sessionIndex.list` of `session/list`.
public struct ACPSessionIndexListOptions: Codable, Equatable, Sendable {
    public let limit: Int
    public let includeWorktrees: Bool
    public let archived: ACPSessionArchiveFilter

    public init(limit: Int = 50, includeWorktrees: Bool, archived: ACPSessionArchiveFilter) {
        self.limit = limit
        self.includeWorktrees = includeWorktrees
        self.archived = archived
    }
}

/// `_meta.sessionIndex` of a `session/list` or `_session/list/changes` row.
/// Every field but `archived` is omitted when the agent does not know it.
public struct ACPSessionIndexRowMeta: Codable, Equatable, Sendable {
    public var archived: Bool?
    public var lastPromptAt: String?
    public var model: String?
    public var forkedFrom: String?
    public var agentWorktree: Bool?
    /// `running`, `idle`, `requires_action`, `error`, or an adapter's own
    /// value such as Codex's `reviewing`.
    public var state: String?
    public var lastTurnEndedAt: String?

    public init(
        archived: Bool? = nil,
        lastPromptAt: String? = nil,
        model: String? = nil,
        forkedFrom: String? = nil,
        agentWorktree: Bool? = nil,
        state: String? = nil,
        lastTurnEndedAt: String? = nil
    ) {
        self.archived = archived
        self.lastPromptAt = lastPromptAt
        self.model = model
        self.forkedFrom = forkedFrom
        self.agentWorktree = agentWorktree
        self.state = state
        self.lastTurnEndedAt = lastTurnEndedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed field drops that field, not the row.
        archived = try? c.decodeIfPresent(Bool.self, forKey: .archived)
        lastPromptAt = try? c.decodeIfPresent(String.self, forKey: .lastPromptAt)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        forkedFrom = try? c.decodeIfPresent(String.self, forKey: .forkedFrom)
        agentWorktree = try? c.decodeIfPresent(Bool.self, forKey: .agentWorktree)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        lastTurnEndedAt = try? c.decodeIfPresent(String.self, forKey: .lastTurnEndedAt)
    }
}

/// The `_meta` of a session index row: only the `sessionIndex` key is read.
public struct ACPSessionIndexRowEnvelope: Codable, Equatable, Sendable {
    public let sessionIndex: ACPSessionIndexRowMeta?

    public init(sessionIndex: ACPSessionIndexRowMeta?) {
        self.sessionIndex = sessionIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionIndex = try? c.decodeIfPresent(ACPSessionIndexRowMeta.self, forKey: .sessionIndex)
    }
}

/// `_session/list/changes` notification params.
public struct ACPSessionListChanges: Codable, Equatable, Sendable {
    public let subscriptionId: String
    public let sessions: [ACPAgentSessionInfo]
    public let removed: [String]

    public init(subscriptionId: String, sessions: [ACPAgentSessionInfo], removed: [String]) {
        self.subscriptionId = subscriptionId
        self.sessions = sessions
        self.removed = removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptionId = try c.decode(String.self, forKey: .subscriptionId)
        sessions = try c.decodeIfPresent([ACPAgentSessionInfo].self, forKey: .sessions) ?? []
        removed = try c.decodeIfPresent([String].self, forKey: .removed) ?? []
    }
}

public struct ACPSessionRenameParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let title: String

    public init(sessionId: String, title: String) {
        self.sessionId = sessionId
        self.title = title
    }
}

/// `_session/archive` and `_session/unarchive` params.
public struct ACPSessionArchiveParams: Codable, Equatable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct ACPSessionListSubscribeParams: Codable, Equatable, Sendable {
    public let cwd: String

    public init(cwd: String) {
        self.cwd = cwd
    }
}

public struct ACPSessionListSubscribeResult: Codable, Equatable, Sendable {
    public let subscriptionId: String
}

public struct ACPSessionListUnsubscribeParams: Codable, Equatable, Sendable {
    public let subscriptionId: String

    public init(subscriptionId: String) {
        self.subscriptionId = subscriptionId
    }
}
