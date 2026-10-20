import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

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
        public let title: Patch<String>
        public let description: Patch<String>
        /// Present — `null` and `{}` included — it replaces the whole set,
        /// so an empty one revokes Cancel.
        public let capabilities: Patch<ACPSubagentCapabilities>
        /// `null` clears the snapshot: no activity is asserted any more.
        public let state: Patch<WorkState>
    }

    /// A nullable patch member: omitted keeps the previous value, `null`
    /// clears it.
    public enum Patch<Value: Equatable & Sendable>: Equatable, Sendable {
        case absent
        case cleared
        case value(Value)

        public var value: Value? {
            if case .value(let value) = self { return value }
            return nil
        }
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
            // `unknown` (the agent cannot currently tell what the child is
            // doing) is NOT terminal: the work may still be live and a later
            // snapshot replaces it, so it decodes to a still-running `.other`.
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
        /// Nil when a `session_message` omits it (content unchanged).
        public let content: [ACPContentBlock]?
        /// A `session_message`: its content replaces whatever the message
        /// held, and `[]`/`null` clears it. A chunk appends.
        public let replacesContent: Bool
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
            // Per the schema, an invalid member decodes as if it were `null`.
            let capabilities: Patch<ACPSubagentCapabilities> = Self.patch(c, .capabilities) {
                try $0.decode(ACPSubagentCapabilities.self, forKey: .capabilities)
            }
            self = .subagentUpdate(.init(
                sessionId: sessionId,
                title: Self.patch(c, .title) { try $0.decode(String.self, forKey: .title) },
                description: Self.patch(c, .description) { try $0.decode(String.self, forKey: .description) },
                capabilities: capabilities,
                state: Self.patch(c, .state) { try Self.workState($0) }))
        case "session_message", "session_message_chunk":
            let isChunk = kind == "session_message_chunk"
            let content: [ACPContentBlock]?
            if isChunk {
                content = [try c.decode(ACPContentBlock.self, forKey: .content)]
            } else if !c.contains(.content) {
                content = nil
            } else {
                // `null` clears like `[]`. Invalid items are skipped, per the
                // schema, rather than failing the whole message.
                let lossy = (try? c.decodeIfPresent([Lossy<ACPContentBlock>].self, forKey: .content)) ?? nil
                content = (lossy ?? []).compactMap(\.value)
            }
            self = .sessionMessage(.init(
                messageId: try c.decode(String.self, forKey: .messageId),
                senderSessionId: (try? c.decodeIfPresent(String.self, forKey: .senderSessionId)) ?? nil,
                recipientSessionId: (try? c.decodeIfPresent(String.self, forKey: .recipientSessionId)) ?? nil,
                content: content,
                replacesContent: !isChunk))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .sessionUpdate, in: c,
                debugDescription: "not a revised subagent update: \(kind)")
        }
    }

    private static func patch<Value>(
        _ c: KeyedDecodingContainer<Keys>,
        _ key: Keys,
        _ decode: (KeyedDecodingContainer<Keys>) throws -> Value
    ) -> Patch<Value> {
        guard c.contains(key) else { return .absent }
        guard let value = try? decode(c) else { return .cleared }
        return .value(value)
    }

    private static func workState(_ c: KeyedDecodingContainer<Keys>) throws -> WorkState {
        let s = try c.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
        let state = try s.decode(String.self, forKey: .state)
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
    /// later ones are patch merges (the RFD resends metadata, and the adapter
    /// re-announces children after a restart). A child announced without a
    /// state starts unconfirmed. A present state — `null` clears it to
    /// unconfirmed — follows as a state update on the same parent.
    public func normalized(sessionId: String) -> [ACPSessionUpdateParams] {
        switch self {
        case .subagentUpdate(let update):
            var result: [ACPSessionUpdateParams] = [.init(
                sessionId: sessionId,
                update: .subagentSpawned(.init(
                    subagentSessionId: update.sessionId,
                    name: update.title.value,
                    task: update.description.value,
                    capabilities: update.capabilities.value ?? .init(),
                    replacesCapabilities: update.capabilities != .absent,
                    clearsName: update.title == .cleared,
                    clearsTask: update.description == .cleared,
                    initialState: update.state.value?.normalized ?? .unconfirmed)))]
            if update.state != .absent {
                result.append(.init(
                    sessionId: sessionId,
                    update: .subagentStateUpdate(.init(
                        subagentSessionId: update.sessionId,
                        state: update.state.value?.normalized ?? .unconfirmed,
                        error: update.state.value?.errorMessage))))
            }
            return result
        case .sessionMessage(let message):
            // A message between sessions is neither a human turn nor an
            // agent answer, so the chunks carry `directed`: the root
            // transcript ignores them, and a child shows a message INTO it
            // (its launch prompt, each SendMessage resume) as the task it
            // was handed — the same row the earlier draft's prompt makes.
            // Claude sends nothing else; the other view of a message (one
            // this session sent elsewhere) is not this transcript's to show.
            // With no recipient, a message is still known not to be INTO
            // this session when this session sent it.
            let addressedHere = message.recipientSessionId.map { $0 == sessionId }
                ?? (message.senderSessionId != sessionId)
            guard addressedHere, let content = message.content else { return [] }
            // An upsert replaces the message's content: the first block
            // carries that, the rest append to it. A clear has no block.
            let blocks = content.isEmpty && message.replacesContent ? [ACPContentBlock.text("")] : content
            return blocks.enumerated().map { offset, block in
                .init(sessionId: sessionId, update: .userMessageChunk(.init(
                    messageId: message.messageId,
                    content: block,
                    directed: .init(
                        senderSessionId: message.senderSessionId,
                        recipientSessionId: message.recipientSessionId,
                        replacesContent: message.replacesContent && offset == 0))))
            }
        }
    }
}

/// Provenance of a chunk normalized from a revised-form `session_message`.
public struct ACPDirectedMessage: Equatable, Sendable {
    public let senderSessionId: String?
    public let recipientSessionId: String?
    /// The chunk starts a whole-content upsert of its message: it replaces
    /// what the message's row held instead of extending it.
    public let replacesContent: Bool

    public init(senderSessionId: String?, recipientSessionId: String?, replacesContent: Bool) {
        self.senderSessionId = senderSessionId
        self.recipientSessionId = recipientSessionId
        self.replacesContent = replacesContent
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

    package init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
