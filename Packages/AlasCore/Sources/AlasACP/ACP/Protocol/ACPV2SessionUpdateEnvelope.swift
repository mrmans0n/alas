import Foundation
import AlasCode

/// V2 session/update notification params, separate from the v1 decoder.
/// The raw codec preserves opaque numeric tokens as well as unknown fields.
public struct ACPV2SessionUpdateEnvelope: Equatable, Sendable {
    public enum MessageKind: Hashable, Sendable { case user, agent, thought }

    public enum ContentMutation: Equatable, Sendable {
        case unchanged
        case replace([LSPJSONValue])
        case append(LSPJSONValue)
    }

    public enum MetadataPatch: Equatable, Sendable {
        case unchanged, clear
        case patch([String: LSPJSONValue])
    }

    public struct Message: Equatable, Sendable {
        public let kind: MessageKind
        public let messageID: String
        public let content: ContentMutation
        public let metadata: MetadataPatch
    }

    public let sessionID: String
    public let rawValue: LSPJSONValue
    /// Nil means an unhandled variant, whose complete payload remains in rawValue.
    public let message: Message?

    public static func decode(from data: Data) throws -> Self {
        try Self(rawValue: LSPJSONValue.decode(from: data))
    }

    public func encodedData() throws -> Data { try rawValue.encodedData() }

    public init(rawValue: LSPJSONValue) throws {
        guard case .object(let params) = rawValue else { throw Self.invalid("params must be an object") }
        guard case .string(let sessionID)? = params["sessionId"] else {
            throw Self.invalid("sessionId must be a string")
        }
        guard case .object(let update)? = params["update"] else {
            throw Self.invalid("update must be an object")
        }
        guard case .string(let variant)? = update["sessionUpdate"] else {
            throw Self.invalid("sessionUpdate must be a string")
        }
        _ = try Self.metadata(params["_meta"])
        self.sessionID = sessionID
        self.rawValue = rawValue
        message = try Self.message(update, variant: variant)
    }

    private static func message(_ fields: [String: LSPJSONValue], variant: String) throws -> Message? {
        let kind: MessageKind
        switch variant {
        case "user_message", "user_message_chunk": kind = .user
        case "agent_message", "agent_message_chunk": kind = .agent
        case "agent_thought", "agent_thought_chunk": kind = .thought
        default: return nil
        }
        guard case .string(let messageID)? = fields["messageId"] else {
            throw invalid("messageId must be a string")
        }
        let patch = try metadata(fields["_meta"])
        let content: ContentMutation
        let isChunk = variant.hasSuffix("_chunk")
        if isChunk {
            guard let block = fields["content"] else { throw invalid("chunk content is required") }
            try validateBlock(block)
            content = .append(block)
        } else {
            switch fields["content"] {
            case nil: content = .unchanged
            case .null: content = .replace([])
            case .array(let blocks):
                for block in blocks { try validateBlock(block) }
                content = .replace(blocks)
            default: throw invalid("message content must be an array or null")
            }
        }
        return Message(kind: kind, messageID: messageID, content: content,
            metadata: isChunk ? .unchanged : patch)
    }

    private static func validateBlock(_ value: LSPJSONValue) throws {
        guard case .object(let fields) = value, case .string? = fields["type"] else {
            throw invalid("content block must be an object with a string type")
        }
    }

    private static func metadata(_ value: LSPJSONValue?) throws -> MetadataPatch {
        switch value {
        case nil: return .unchanged
        case .null: return .clear
        case .object(let fields): return .patch(fields)
        default: throw invalid("_meta must be an object or null")
        }
    }

    private static func invalid(_ reason: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid v2 session/update: \(reason)"))
    }
}
