import Foundation

enum ACPMessage: Equatable {
    case user(id: UUID, text: String, attachments: [Attachment])
    case agent(id: UUID, StreamingText)
    case thought(id: UUID, StreamingText)
    case toolCall(ToolCall)
    case fileEdit(id: UUID, FileEdit)
    case plan(id: UUID, [PlanItem])
    case systemNotice(id: UUID, text: String)

    var stableId: String {
        switch self {
        case .user(let id, _, _),
             .agent(let id, _),
             .thought(let id, _),
             .fileEdit(let id, _),
             .plan(let id, _),
             .systemNotice(let id, _):
            return id.uuidString
        case .toolCall(let tc):
            return "tc-\(tc.toolCallId)"
        }
    }

    var kind: String {
        switch self {
        case .user: "user"
        case .agent: "agent"
        case .thought: "thought"
        case .toolCall: "tool_call"
        case .fileEdit: "file_edit"
        case .plan: "plan"
        case .systemNotice: "system"
        }
    }

    struct Attachment: Codable, Equatable, Hashable, Sendable {
        let uri: String
        let name: String?
    }

    struct ToolCall: Codable, Equatable, Hashable, Sendable {
        let toolCallId: String
        var title: String
        var kind: String?
        var status: String
        /// Full text body of the tool call as the agent last reported it.
        /// Rendered inside the expanded card. Updated in place when the
        /// agent sends `tool_call_update` with new content.
        var content: String
        /// One-line teaser shown on the collapsed row (first text chunk,
        /// truncated). Computed at apply() time so we don't repeatedly
        /// scan the full content during rendering.
        var preview: String?
        var locations: [String]

        init(toolCallId: String, title: String, kind: String? = nil,
             status: String, content: String = "", preview: String? = nil,
             locations: [String] = []) {
            self.toolCallId = toolCallId
            self.title = title
            self.kind = kind
            self.status = status
            self.content = content
            self.preview = preview
            self.locations = locations
        }

        // Backwards-compatible decoder: older messages persisted only a
        // `contentSummary` field. We still read it so the previous
        // session history doesn't go blank after upgrade.
        enum CodingKeys: String, CodingKey {
            case toolCallId, title, kind, status, content, preview,
                 contentSummary, locations
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            toolCallId = try c.decode(String.self, forKey: .toolCallId)
            title = try c.decode(String.self, forKey: .title)
            kind = try? c.decode(String.self, forKey: .kind)
            status = try c.decode(String.self, forKey: .status)
            content = (try? c.decode(String.self, forKey: .content)) ?? ""
            preview = (try? c.decode(String.self, forKey: .preview))
                ?? (try? c.decode(String.self, forKey: .contentSummary))
            locations = (try? c.decode([String].self, forKey: .locations)) ?? []
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(toolCallId, forKey: .toolCallId)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(kind, forKey: .kind)
            try c.encode(status, forKey: .status)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(preview, forKey: .preview)
            try c.encode(locations, forKey: .locations)
        }
    }

    struct FileEdit: Codable, Equatable, Hashable, Sendable {
        let path: String
        var added: Int
        var removed: Int
    }

    struct PlanItem: Codable, Equatable, Hashable, Sendable {
        let content: String
        var status: String   // "pending" | "in_progress" | "completed"
    }
}

enum ACPMessageCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    @MainActor
    static func encode(_ m: ACPMessage) throws -> Data {
        switch m {
        case .user(_, let text, let atts): return try encoder.encode(UserPayload(text: text, attachments: atts))
        case .agent(_, let buf):            return try encoder.encode(TextPayload(text: buf.value))
        case .thought(_, let buf):          return try encoder.encode(TextPayload(text: buf.value))
        case .toolCall(let tc):             return try encoder.encode(tc)
        case .fileEdit(_, let fe):          return try encoder.encode(fe)
        case .plan(_, let items):           return try encoder.encode(PlanPayload(items: items))
        case .systemNotice(_, let text):    return try encoder.encode(TextPayload(text: text))
        }
    }

    @MainActor
    static func decode(kind: String, payload: Data) throws -> ACPMessage {
        switch kind {
        case "user":
            let p = try JSONDecoder().decode(UserPayload.self, from: payload)
            return .user(id: UUID(), text: p.text, attachments: p.attachments)
        case "agent":
            return .agent(id: UUID(), StreamingText(try JSONDecoder().decode(TextPayload.self, from: payload).text))
        case "thought":
            return .thought(id: UUID(), StreamingText(try JSONDecoder().decode(TextPayload.self, from: payload).text))
        case "tool_call":
            return .toolCall(try JSONDecoder().decode(ACPMessage.ToolCall.self, from: payload))
        case "file_edit":
            return .fileEdit(id: UUID(), try JSONDecoder().decode(ACPMessage.FileEdit.self, from: payload))
        case "plan":
            return .plan(id: UUID(), try JSONDecoder().decode(PlanPayload.self, from: payload).items)
        case "system":
            return .systemNotice(id: UUID(), text: try JSONDecoder().decode(TextPayload.self, from: payload).text)
        default:
            return .systemNotice(id: UUID(), text: "(unknown message kind: \(kind))")
        }
    }

    private struct TextPayload: Codable { let text: String }
    private struct UserPayload: Codable { let text: String
    let attachments: [ACPMessage.Attachment] }
    private struct PlanPayload: Codable { let items: [ACPMessage.PlanItem] }
}
