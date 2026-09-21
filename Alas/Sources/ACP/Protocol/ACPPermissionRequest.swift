import Foundation

/// `session/request_permission` — server-to-client.
///
/// Wire shape per the ACP spec: `toolCall` is a `ToolCallUpdate` (every
/// field optional) — *not* a full `ToolCall`. The original adapter sends
/// only `{ toolCallId, title, rawInput }`. Decoding into the strict
/// `ACPToolCallPayload` failed silently and the user never saw the prompt.
///
/// `metadata` carries the request's own `_meta` (decoded, not interpreted
/// here — see `ACPPermissionPresentation`). claude-agent-acp ≥ 0.71 and
/// codex-acp ≥ 1.7 attach a shared `_meta.permission` presentation
/// extension (title/description/defaultToNo); older adapters omit `_meta`
/// entirely and decode to `nil`.
struct ACPPermissionRequestParams: Codable, Equatable {
    let sessionId: String
    let toolCall: ACPPermissionToolCall
    let options: [ACPPermissionOption]
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case sessionId, toolCall, options
        case metadata = "_meta"
    }

    init(sessionId: String, toolCall: ACPPermissionToolCall, options: [ACPPermissionOption], metadata: AnyCodable? = nil) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        toolCall = try c.decode(ACPPermissionToolCall.self, forKey: .toolCall)
        options = try c.decode([ACPPermissionOption].self, forKey: .options)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

/// Lenient toolCall payload used inside permission requests. Mirrors the
/// spec's `ToolCallUpdate` — only `toolCallId` is required.
struct ACPPermissionToolCall: Codable, Equatable {
    let toolCallId: String
    let title: String?
    let kind: String?
    let status: String?
    let content: [ACPToolCallContent]?
    let locations: [ACPToolLocation]?
    let rawInput: AnyCodable?
    let rawOutput: AnyCodable?
    /// Stable tool identifier (ACP 1.22+). See `ACPToolCallPayload.name`.
    let name: String?
    /// `_meta.claudeCode.mcpServer` for `mcp__*` calls — see `mcpServerName`.
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput, name
        case metadata = "_meta"
    }

    init(toolCallId: String, title: String? = nil, kind: String? = nil, status: String? = nil,
         content: [ACPToolCallContent]? = nil, locations: [ACPToolLocation]? = nil,
         rawInput: AnyCodable? = nil, rawOutput: AnyCodable? = nil,
         name: String? = nil, metadata: AnyCodable? = nil) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.name = name
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try c.decode(String.self, forKey: .toolCallId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        content = try? c.decodeIfPresent([ACPToolCallContent].self, forKey: .content)
        locations = try? c.decodeIfPresent([ACPToolLocation].self, forKey: .locations)
        rawInput = try? c.decodeIfPresent(AnyCodable.self, forKey: .rawInput)
        rawOutput = try? c.decodeIfPresent(AnyCodable.self, forKey: .rawOutput)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

struct ACPPermissionOption: Codable, Equatable, Identifiable, Hashable {
    let optionId: String
    let name: String
    let kind: String        // "allow_once" | "allow_always" | "reject_once" | "reject_always"
    /// `_meta.permission` for this option — see `presentationDescription`.
    let metadata: AnyCodable?
    var id: String { optionId }

    private enum CodingKeys: String, CodingKey {
        case optionId, name, kind
        case metadata = "_meta"
    }

    init(optionId: String, name: String, kind: String, metadata: AnyCodable? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try c.decode(String.self, forKey: .optionId)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

/// Shared helpers for reading the loosely-typed `_meta` trees carried by
/// permission requests. Mirrors `ACPContextCompaction`'s extraction style.
private enum ACPPermissionMeta {
    static func object(_ value: AnyCodable?) -> [String: AnyCodable]? {
        guard let value else { return nil }
        if let object = value.value as? [String: AnyCodable] { return object }
        if let object = value.value as? [String: Any] {
            return object.mapValues { $0 as? AnyCodable ?? AnyCodable($0) }
        }
        return nil
    }

    static func nested(_ object: [String: AnyCodable]?, _ key: String) -> [String: AnyCodable]? {
        object.flatMap { $0[key] }.flatMap(self.object)
    }

    static func string(_ object: [String: AnyCodable]?, _ key: String) -> String? {
        object?[key]?.value as? String
    }

    static func int(_ object: [String: AnyCodable]?, _ key: String) -> Int? {
        object?[key]?.value as? Int
    }

    static func bool(_ object: [String: AnyCodable]?, _ key: String) -> Bool? {
        object?[key]?.value as? Bool
    }
}

/// Decoded `_meta.permission` presentation attached by claude-agent-acp
/// (≥ 0.71) and codex-acp (≥ 1.7) to `session/request_permission`. Gated on
/// `version == 1`: missing, malformed, or future-versioned `_meta` decodes
/// to `nil` and the prompt falls back to today's plain rendering.
struct ACPPermissionPresentation: Equatable {
    let title: String?
    let description: String?
    let defaultToNo: Bool

    init?(metadata: AnyCodable?) {
        let permission = ACPPermissionMeta.nested(ACPPermissionMeta.object(metadata), "permission")
        guard ACPPermissionMeta.int(permission, "version") == 1 else { return nil }
        title = ACPPermissionMeta.string(permission, "title")
        description = ACPPermissionMeta.string(permission, "description")
        defaultToNo = ACPPermissionMeta.bool(permission, "defaultToNo") ?? false
    }
}

extension ACPPermissionOption {
    /// Per-option reason from `_meta.permission.description`.
    var presentationDescription: String? {
        let permission = ACPPermissionMeta.nested(ACPPermissionMeta.object(metadata), "permission")
        guard ACPPermissionMeta.int(permission, "version") == 1 else { return nil }
        return ACPPermissionMeta.string(permission, "description")
    }
}

extension ACPPermissionToolCall {
    /// MCP server name from `_meta.claudeCode.mcpServer.name`, shown for
    /// tool calls proxied through an MCP server.
    var mcpServerName: String? {
        let claudeCode = ACPPermissionMeta.nested(ACPPermissionMeta.object(metadata), "claudeCode")
        let mcpServer = ACPPermissionMeta.nested(claudeCode, "mcpServer")
        return ACPPermissionMeta.string(mcpServer, "name")
    }
}

/// Response: `{ outcome: { outcome: "selected", optionId: "..." } }` or
/// `{ outcome: { outcome: "cancelled" } }`.
struct ACPPermissionResponse: Codable, Equatable {
    let outcome: Outcome

    enum Outcome: Codable, Equatable {
        case selected(optionId: String)
        case cancelled

        private enum K: String, CodingKey { case outcome, optionId }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let kind = try c.decode(String.self, forKey: .outcome)
            switch kind {
            case "selected":  self = .selected(optionId: try c.decode(String.self, forKey: .optionId))
            case "cancelled": self = .cancelled
            default:          self = .cancelled
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .selected(let id):
                try c.encode("selected", forKey: .outcome)
                try c.encode(id, forKey: .optionId)
            case .cancelled:
                try c.encode("cancelled", forKey: .outcome)
            }
        }
    }
}
