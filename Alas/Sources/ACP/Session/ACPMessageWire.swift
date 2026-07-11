import Foundation

/// Sendable, isolation-free intermediate between persisted message bytes
/// and the main-actor `ACPMessage` used by views. The hydrator decodes
/// payloads into `ACPMessageWire` on a background actor; the main hop
/// converts each variant into a full `ACPMessage`, which is the only
/// place we allocate `StreamingText` (a `@MainActor` class).
enum ACPMessageWire: Sendable {
    case user(messageId: String?, text: String, attachments: [ACPMessage.Attachment])
    case agent(messageId: String?, text: String)
    case thought(messageId: String?, text: String)
    case toolCall(ACPMessage.ToolCall)
    case fileEdit(ACPMessage.FileEdit)
    case plan([ACPMessage.PlanItem])
    case systemNotice(text: String)

    var isAgentSideProgress: Bool {
        switch self {
        case .agent, .thought, .toolCall, .fileEdit, .plan:
            return true
        case .user, .systemNotice:
            return false
        }
    }

    /// Decode a persisted `(kind, payload)` pair into the matching wire variant.
    /// Mirrors `ACPMessageCodec.decode` but produces Sendable values and is
    /// safe to call from any isolation domain. Unknown kinds become system
    /// notices (matching the legacy fallback).
    ///
    /// `decoder` may be a shared instance reused across many calls (e.g. by
    /// `ACPSessionHydrator` when decoding an entire transcript); defaults to
    /// a per-call instance when callers don't care.
    static func decode(
        kind: String,
        payload: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> ACPMessageWire {
        switch kind {
        case "user":
            let p = try decoder.decode(UserPayload.self, from: payload)
            return .user(messageId: p.messageId, text: p.text, attachments: p.attachments)
        case "agent":
            let p = try decoder.decode(TextPayload.self, from: payload)
            return .agent(messageId: p.messageId, text: p.text)
        case "thought":
            let p = try decoder.decode(TextPayload.self, from: payload)
            return .thought(messageId: p.messageId, text: p.text)
        case "tool_call":
            return .toolCall(try decoder.decode(ACPMessage.ToolCall.self, from: payload))
        case "file_edit":
            return .fileEdit(try decoder.decode(ACPMessage.FileEdit.self, from: payload))
        case "plan":
            return .plan(try decoder.decode(PlanPayload.self, from: payload).items)
        case "system":
            return .systemNotice(text: try decoder.decode(TextPayload.self, from: payload).text)
        default:
            return .systemNotice(text: "(unknown message kind: \(kind))")
        }
    }

    /// Convert to a full `ACPMessage`. Must run on the main actor because
    /// `StreamingText` is `@MainActor`-isolated.
    @MainActor
    func toMessage() -> ACPMessage {
        switch self {
        case .user(let messageId, let text, let attachments):
            return .user(id: UUID(), messageId: messageId, text: text, attachments: attachments)
        case .agent(let messageId, let text):
            return .agent(id: UUID(), messageId: messageId, StreamingText(text))
        case .thought(let messageId, let text):
            return .thought(id: UUID(), messageId: messageId, StreamingText(text))
        case .toolCall(let tc):
            return .toolCall(tc)
        case .fileEdit(let fe):
            return .fileEdit(id: UUID(), fe)
        case .plan(let items):
            return .plan(id: UUID(), items)
        case .systemNotice(let text):
            return .systemNotice(id: UUID(), text: text)
        }
    }

    private struct TextPayload: Decodable {
        let messageId: String?
        let text: String
    }
    private struct UserPayload: Decodable {
        let messageId: String?
        let text: String
        let attachments: [ACPMessage.Attachment]
    }
    private struct PlanPayload: Decodable { let items: [ACPMessage.PlanItem] }
}
