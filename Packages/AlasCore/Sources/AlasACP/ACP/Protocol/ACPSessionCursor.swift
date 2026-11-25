import Foundation
import AlasCode
import AlasFoundation

// Session cursors (unstable ACP RFD) and the in-place rewind of our Claude
// and Codex adapter forks. A cursor is a position of a session; the adapters
// announce the one before each user message that follows another entry.
// `session/fork` with its `cursorId` copies the history before it, and
// `_session/rewind` cuts the same session back to it.

/// `cursor_update`: one position of the session and what can act at it.
public struct ACPSessionCursor: Codable, Equatable, Sendable {
    /// What the cursor lies beside, by the id the agent gave it.
    public enum Entity: Codable, Hashable, Sendable {
        case userMessage(String)
        case agentMessage(String)
        case agentThought(String)
        case toolCall(String)
        case compaction(String)
    }

    public enum Position: String, Codable, Sendable {
        case before
        case after
    }

    public struct Anchor: Codable, Hashable, Sendable {
        public let entity: Entity
        public let position: Position

        public init(entity: Entity, position: Position) {
            self.entity = entity
            self.position = position
        }
    }

    public let cursorId: String
    public let anchor: Anchor
    /// `session/fork` accepts the cursor.
    public let canFork: Bool
    /// `_session/rewind` accepts the cursor.
    public let canRewind: Bool

    public init(cursorId: String, anchor: Anchor, canFork: Bool = true, canRewind: Bool = false) {
        self.cursorId = cursorId
        self.anchor = anchor
        self.canFork = canFork
        self.canRewind = canRewind
    }

    /// Nil for an update this client cannot place: no id, or an anchor of a
    /// kind or position it doesn't know.
    public init?(wire value: LSPJSONValue) {
        guard case .object(let update) = value,
              case .string(let cursorId)? = update["cursorId"], !cursorId.isEmpty,
              case .object(let anchor)? = update["anchor"],
              case .string(let type)? = anchor["type"],
              case .string(let rawPosition)? = anchor["position"],
              let position = Position(rawValue: rawPosition)
        else { return nil }
        func id(_ key: String) -> String? {
            if case .string(let id)? = anchor[key], !id.isEmpty { return id }
            return nil
        }
        let entity: Entity? = switch type {
        case "user_message": id("messageId").map(Entity.userMessage)
        case "agent_message": id("messageId").map(Entity.agentMessage)
        case "agent_thought": id("messageId").map(Entity.agentThought)
        case "tool_call": id("toolCallId").map(Entity.toolCall)
        case "compaction": id("compactionId").map(Entity.compaction)
        default: nil
        }
        guard let entity else { return nil }
        var capabilities: [String: LSPJSONValue] = [:]
        if case .object(let declared)? = update["capabilities"] { capabilities = declared }
        func declares(_ key: String) -> Bool {
            if case .object? = capabilities[key] { return true }
            return false
        }
        self.init(
            cursorId: cursorId,
            anchor: .init(entity: entity, position: position),
            canFork: declares("fork"),
            canRewind: declares("rewind"))
    }
}

/// `_session/rewind`.
public struct ACPSessionRewindParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let cursorId: String

    public init(sessionId: String, cursorId: String) {
        self.sessionId = sessionId
        self.cursorId = cursorId
    }
}

/// Why the agent left the conversation as it was.
public enum ACPSessionRewindRefusal: Equatable, Sendable {
    case busy
    case backgroundWork
    case beforeCompaction
    case clearedContext
    case providerRefused
    case persistFailed
    case other(String)

    public init(wire: String?) {
        switch wire {
        case "busy": self = .busy
        case "backgroundWork": self = .backgroundWork
        case "beforeCompaction": self = .beforeCompaction
        case "clearedContext": self = .clearedContext
        case "providerRefused": self = .providerRefused
        case "persistFailed": self = .persistFailed
        default: self = .other(wire ?? "")
        }
    }

    /// The agent cannot cut here at all, but can still fork from the message.
    public var suggestsFork: Bool {
        self == .beforeCompaction || self == .clearedContext
    }
}

/// The answer to `_session/rewind`: the cut is live and persisted, or
/// nothing changed.
public enum ACPSessionRewindOutcome: Equatable, Sendable {
    case rewound
    case refused(ACPSessionRewindRefusal)
}

extension ACPSessionRewindOutcome: Decodable {
    private enum CodingKeys: String, CodingKey { case rewound, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(Bool.self, forKey: .rewound) {
            self = .rewound
        } else {
            self = .refused(.init(wire: try? c.decodeIfPresent(String.self, forKey: .reason)))
        }
    }
}
