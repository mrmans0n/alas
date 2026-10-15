import Foundation

/// The revised native subagent form of ACP RFD 1992, sent by
/// claude-agent-acp >= 0.90 to every non-AIR client that declares
/// `clientCapabilities.subagents`.
///
/// It replaces the earlier draft's `subagent_spawned` / `subagent_state_update`
/// with one patch-shaped `subagent_update` on the parent, and delivers the
/// child's prompts as `session_message` / `session_message_chunk` on the
/// child session. A child is reusable: `idle` ends its current work, and a
/// SendMessage resume brings the SAME session id back to `running`.
///
/// Like OpenCode's variant, Alas normalizes it into the earlier shapes at the
/// client boundary (see `ACPSessionUpdateFrame`) so exactly one routing,
/// replay and persistence path exists downstream.
public enum ACPRevisedSubagentUpdate: Decodable, Equatable, Sendable {
    case subagentUpdate(SubagentUpdate)
    case sessionMessage(SessionMessage)

    public static let kinds: Set<String> = ["subagent_update", "session_message", "session_message_chunk"]

    /// `{"sessionUpdate": "subagent_update", ...}` on the immediate parent.
    /// Every member but `sessionId` is a patch: absent keeps the previous
    /// value, so a state-only update must not wipe the announced title.
    public struct SubagentUpdate: Equatable, Sendable {
        public let sessionId: String
        public let title: String?
        public let description: String?
        /// Nil when absent. A concrete object replaces the whole set.
        public let capabilities: ACPSubagentCapabilities?
        /// Nil when absent or `null`: neither asserts any activity.
        public let state: WorkState?
    }

    /// The RFD's whole-object state snapshot.
    public struct WorkState: Equatable, Sendable {
        public let state: String
        public let stopReason: String?
        public let errorMessage: String?

        /// The Alas lifecycle state this snapshot stands for.
        ///
        /// `idle` is not terminal in the RFD — the child can be messaged
        /// again — but it does end the work Alas shows a spinner for. A
        /// resume reports `running` again, and `ACPSubagentRun` lets a live
        /// non-terminal state reopen a finished row. An idle with no stop
        /// reason (a worker restart, a background child that outlived its
        /// parent's cancel) reports neither a failure nor a cancellation,
        /// so it is shown as done.
        public var normalized: ACPSubagentState {
            switch state {
            case "idle":
                switch stopReason {
                case "cancelled": return .cancelled
                case "error": return .failed
                default: return .completed
                }
            // The agent can no longer tell what the child is doing — the
            // adapter's own mapping of the earlier draft's `disconnected`.
            case "unknown": return .disconnected
            default: return ACPSubagentState(rawValue: state)
            }
        }
    }

    /// `session_message` (whole content, an upsert) or
    /// `session_message_chunk` (one appended block) on the session whose
    /// transcript holds it.
    public struct SessionMessage: Equatable, Sendable {
        public let messageId: String
        public let senderSessionId: String?
        public let recipientSessionId: String?
        public let content: [ACPContentBlock]
    }

    private enum Keys: String, CodingKey {
        case sessionUpdate, sessionId, title, description, capabilities, state
        case messageId, senderSessionId, recipientSessionId, content
    }

    private enum StateKeys: String, CodingKey {
        case state, stopReason, error
    }

    private enum ErrorKeys: String, CodingKey {
        case message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "subagent_update":
            let sessionId = try c.decode(String.self, forKey: .sessionId)
            let title: String? = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
            let description: String? = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? nil
            let capabilities: ACPSubagentCapabilities? =
                (try? c.decodeIfPresent(ACPSubagentCapabilities.self, forKey: .capabilities)) ?? nil
            self = .subagentUpdate(.init(
                sessionId: sessionId,
                title: title,
                description: description,
                capabilities: capabilities,
                state: Self.workState(c)))
        case "session_message", "session_message_chunk":
            let content: [ACPContentBlock]
            if kind == "session_message_chunk" {
                content = [try c.decode(ACPContentBlock.self, forKey: .content)]
            } else {
                // Invalid items are skipped, per the schema, rather than
                // failing the whole message.
                let lossy = (try? c.decodeIfPresent([Lossy<ACPContentBlock>].self, forKey: .content)) ?? nil
                content = (lossy ?? []).compactMap(\.value)
            }
            self = .sessionMessage(.init(
                messageId: try c.decode(String.self, forKey: .messageId),
                senderSessionId: (try? c.decodeIfPresent(String.self, forKey: .senderSessionId)) ?? nil,
                recipientSessionId: (try? c.decodeIfPresent(String.self, forKey: .recipientSessionId)) ?? nil,
                content: content))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .sessionUpdate, in: c,
                debugDescription: "not a revised subagent update: \(kind)")
        }
    }

    private static func workState(_ c: KeyedDecodingContainer<Keys>) -> WorkState? {
        guard let s = try? c.nestedContainer(keyedBy: StateKeys.self, forKey: .state),
              let state = try? s.decode(String.self, forKey: .state)
        else { return nil }
        let error = try? s.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
        return .init(
            state: state,
            stopReason: (try? s.decodeIfPresent(String.self, forKey: .stopReason)) ?? nil,
            errorMessage: error.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .message)) ?? nil })
    }

    /// The equivalent earlier-draft notifications, in the order they must be
    /// applied. `sessionId` is the enclosing session of the wire frame.
    ///
    /// Every `subagent_update` yields a spawn: the first announces the child,
    /// later ones are idempotent merges (the RFD resends metadata, and the
    /// adapter re-announces children after a restart). A concrete state
    /// follows it as a state update on the same parent.
    public func normalized(sessionId: String) -> [ACPSessionUpdateParams] {
        switch self {
        case .subagentUpdate(let update):
            var result: [ACPSessionUpdateParams] = [.init(
                sessionId: sessionId,
                update: .subagentSpawned(.init(
                    subagentSessionId: update.sessionId,
                    name: update.title,
                    task: update.description,
                    capabilities: update.capabilities ?? .init())))]
            if let state = update.state {
                result.append(.init(
                    sessionId: sessionId,
                    update: .subagentStateUpdate(.init(
                        subagentSessionId: update.sessionId,
                        state: state.normalized,
                        error: state.errorMessage))))
            }
            return result
        case .sessionMessage(let message):
            // Claude only sends messages INTO a child (its launch prompt and
            // each SendMessage resume), which is the child's user turn. A
            // message the session itself sent elsewhere is its own output.
            // Anything else is not this transcript's to show — never a user
            // turn, which on the root would claim prompt ownership.
            let addressedHere = message.recipientSessionId.map { $0 == sessionId } ?? true
            let isOutgoing = !addressedHere && message.senderSessionId == sessionId
            guard addressedHere || isOutgoing else { return [] }
            return message.content.map { block in
                let chunk = ACPTextChunk(messageId: message.messageId, content: block)
                return .init(
                    sessionId: sessionId,
                    update: isOutgoing ? .agentMessageChunk(chunk) : .userMessageChunk(chunk))
            }
        }
    }
}

/// The params of one `session/update` frame, as the standard notifications
/// Alas routes. Both forms of native subagents land in the same shapes here,
/// so every transport must decode `session/update` through this type.
///
/// Decode-only: it exists to fan one wire frame out into several updates
/// (the durable acknowledgement belongs to the LAST of them).
public struct ACPSessionUpdateFrame: Codable, Sendable {
    public let updates: [ACPSessionUpdateParams]

    private enum Keys: String, CodingKey {
        case sessionId, update
    }

    private enum UpdateKeys: String, CodingKey {
        case sessionUpdate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.nestedContainer(keyedBy: UpdateKeys.self, forKey: .update)
            .decode(String.self, forKey: .sessionUpdate)
        guard ACPRevisedSubagentUpdate.kinds.contains(kind) else {
            updates = [try ACPSessionUpdateParams(from: decoder)]
            return
        }
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        updates = try c.decode(ACPRevisedSubagentUpdate.self, forKey: .update)
            .normalized(sessionId: sessionId)
    }

    public func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(self, .init(
            codingPath: encoder.codingPath,
            debugDescription: "ACPSessionUpdateFrame is decode-only"))
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
