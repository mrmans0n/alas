import Foundation

struct ACPSessionUpdateParams: Codable, Equatable {
    let sessionId: String
    let update: ACPSessionUpdate
}

enum ACPSessionUpdate: Codable, Equatable {
    case userMessageChunk(ACPTextChunk)
    case agentMessageChunk(ACPTextChunk)
    case agentThoughtChunk(ACPTextChunk)
    case toolCall(ACPToolCallPayload)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableModelsUpdate([ACPModelInfo])
    case currentModeUpdate(modeId: String)
    case currentModelUpdate(modelId: String)
    case sessionConfigOptionsUpdate([ACPConfigOption])
    case availableCommandsUpdate([ACPPromptSuggestion])
    case usageUpdate(ACPUsageInfo)
    case sessionInfoUpdate(ACPSessionInfoUpdate)
    case unknown(String)

    static func userMessageChunk(_ content: ACPContentBlock) -> ACPSessionUpdate {
        .userMessageChunk(.init(content: content))
    }

    static func agentMessageChunk(_ content: ACPContentBlock) -> ACPSessionUpdate {
        .agentMessageChunk(.init(content: content))
    }

    static func agentThoughtChunk(_ content: ACPContentBlock) -> ACPSessionUpdate {
        .agentThoughtChunk(.init(content: content))
    }

    private enum Keys: String, CodingKey {
        case sessionUpdate, content, availableModels, modeId, modelId,
             entries, availableCommands, configOptions, title, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "user_message_chunk":   self = .userMessageChunk(try ACPTextChunk(from: decoder))
        case "agent_message_chunk":  self = .agentMessageChunk(try ACPTextChunk(from: decoder))
        case "agent_thought_chunk":  self = .agentThoughtChunk(try ACPTextChunk(from: decoder))
        case "tool_call":
            self = .toolCall(try ACPToolCallPayload(from: decoder))
        case "tool_call_update":
            self = .toolCallUpdate(try ACPToolCallUpdate(from: decoder))
        case "plan":
            self = .plan(try c.decode([ACPPlanEntry].self, forKey: .entries))
        case "available_models_update":
            self = .availableModelsUpdate(try c.decode([ACPModelInfo].self, forKey: .availableModels))
        case "current_mode_update":
            self = .currentModeUpdate(modeId: try c.decode(String.self, forKey: .modeId))
        case "current_model_update":
            self = .currentModelUpdate(modelId: try c.decode(String.self, forKey: .modelId))
        // Spec uses `config_option_update`; some drafts/implementations
        // emit `session_config_options_update`. Accept both.
        case "config_option_update", "session_config_options_update":
            self = .sessionConfigOptionsUpdate(
                try c.decode([ACPConfigOption].self, forKey: .configOptions))
        case "available_commands_update":
            // Wire format: `{ availableCommands: [{ name, description, input }] }`.
            // We don't surface `input` (argument hints) in v1.
            let raw = (try? c.decode([ACPAvailableCommand].self, forKey: .availableCommands)) ?? []
            self = .availableCommandsUpdate(raw.map {
                let cmd = $0.name.hasPrefix("/") ? $0.name : "/" + $0.name
                return ACPPromptSuggestion(command: cmd, description: $0.description)
            })
        case "usage_update":
            self = .usageUpdate(try ACPUsageInfo(from: decoder))
        case "session_info_update":
            self = .sessionInfoUpdate(try ACPSessionInfoUpdate(from: decoder))
        default:
            self = .unknown(kind)
        }
    }

    /// Mirror of the wire-format command shape from `available_commands_update`.
    /// Decoded then mapped to `ACPPromptSuggestion` so the rest of the
    /// codebase doesn't need to learn the protocol's leaner shape.
    private struct ACPAvailableCommand: Codable {
        let name: String
        let description: String?
    }

    func encode(to encoder: Encoder) throws {
        // Encoding not required for v1 (we only receive these). Implement when needed.
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .userMessageChunk(let b):  try c.encode("user_message_chunk", forKey: .sessionUpdate)
        try b.encodeFields(to: encoder)
        case .agentMessageChunk(let b): try c.encode("agent_message_chunk", forKey: .sessionUpdate)
        try b.encodeFields(to: encoder)
        case .agentThoughtChunk(let b): try c.encode("agent_thought_chunk", forKey: .sessionUpdate)
        try b.encodeFields(to: encoder)
        case .plan(let e):              try c.encode("plan", forKey: .sessionUpdate)
        try c.encode(e, forKey: .entries)
        case .availableModelsUpdate(let m): try c.encode("available_models_update", forKey: .sessionUpdate)
        try c.encode(m, forKey: .availableModels)
        case .currentModeUpdate(let m):     try c.encode("current_mode_update", forKey: .sessionUpdate)
        try c.encode(m, forKey: .modeId)
        case .currentModelUpdate(let m):
            try c.encode("current_model_update", forKey: .sessionUpdate)
            try c.encode(m, forKey: .modelId)
        case .sessionConfigOptionsUpdate(let opts):
            try c.encode("session_config_options_update", forKey: .sessionUpdate)
            try c.encode(opts, forKey: .configOptions)
        case .sessionInfoUpdate(let info):
            try c.encode("session_info_update", forKey: .sessionUpdate)
            switch info.title {
            case .absent:
                break
            case .null:
                try c.encodeNil(forKey: .title)
            case .value(let title):
                try c.encode(title, forKey: .title)
            }
            try c.encodeIfPresent(info.updatedAt, forKey: .updatedAt)
        case .availableCommandsUpdate: break // not produced by us
        case .toolCall, .toolCallUpdate, .usageUpdate, .unknown: break
        }
    }
}

struct ACPTextChunk: Codable, Equatable {
    let messageId: String?
    let content: ACPContentBlock

    init(messageId: String? = nil, content: ACPContentBlock) {
        self.messageId = messageId
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case messageId, content
    }

    func encodeFields(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(messageId, forKey: .messageId)
        try c.encode(content, forKey: .content)
    }
}

struct ACPToolCallPayload: Codable, Equatable {
    let toolCallId: String
    let title: String
    let kind: String?
    let status: String
    let content: [ACPToolCallContent]?
    let locations: [ACPToolLocation]?
    let rawInput: AnyCodable?
    let rawOutput: AnyCodable?
}

struct ACPToolCallUpdate: Codable, Equatable {
    let toolCallId: String
    let status: String?
    let content: [ACPToolCallContent]?
    let rawOutput: AnyCodable?
}

struct ACPToolLocation: Codable, Equatable {
    let path: String
    let line: Int?
}

struct ACPPlanEntry: Codable, Equatable {
    let content: String
    let priority: String?
    let status: String
}

/// Context-window usage from the ACP `usage_update` notification.
/// `used`/`size` are token counts; `cost` is cumulative session cost when the
/// agent reports it. A malformed/partial `cost` must not sink the whole update,
/// so it is decoded defensively to `nil`.
struct ACPUsageInfo: Codable, Equatable {
    let used: Int
    let size: Int
    let cost: Cost?

    struct Cost: Codable, Equatable {
        let amount: Double
        let currency: String
    }

    private enum CodingKeys: String, CodingKey { case used, size, cost }

    init(used: Int, size: Int, cost: Cost?) {
        self.used = used
        self.size = size
        self.cost = cost
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        used = try c.decode(Int.self, forKey: .used)
        size = try c.decode(Int.self, forKey: .size)
        cost = try? c.decodeIfPresent(Cost.self, forKey: .cost)
    }
}

struct ACPSessionInfoUpdate: Codable, Equatable {
    let title: ACPStringFieldUpdate
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey { case title, updatedAt }

    init(title: ACPStringFieldUpdate = .absent, updatedAt: String?) {
        self.title = title
        self.updatedAt = updatedAt
    }

    init(title: String?, updatedAt: String?) {
        self.title = title.map(ACPStringFieldUpdate.value) ?? .absent
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if !c.contains(.title) {
            title = .absent
        } else if (try? c.decodeNil(forKey: .title)) == true {
            title = .null
        } else if let value = try? c.decode(String.self, forKey: .title) {
            title = .value(value)
        } else {
            title = .absent
        }
        updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch title {
        case .absent:
            break
        case .null:
            try c.encodeNil(forKey: .title)
        case .value(let title):
            try c.encode(title, forKey: .title)
        }
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }
}

enum ACPStringFieldUpdate: Equatable {
    case absent
    case null
    case value(String)
}
