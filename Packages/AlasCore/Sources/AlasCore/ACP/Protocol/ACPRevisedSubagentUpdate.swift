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
            // A message between sessions is neither a human turn nor an
            // agent answer, so the chunks carry `directed`: the root
            // transcript ignores them, and a child shows a message INTO it
            // (its launch prompt, each SendMessage resume) as the task it
            // was handed — the same row the earlier draft's prompt makes.
            // Claude sends nothing else; the other view of a message (one
            // this session sent elsewhere) is not this transcript's to show.
            guard message.recipientSessionId.map({ $0 == sessionId }) ?? true,
                  let content = message.content else { return [] }
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

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
