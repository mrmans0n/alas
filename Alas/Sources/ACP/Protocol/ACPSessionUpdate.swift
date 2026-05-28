import Foundation

struct ACPSessionUpdateParams: Codable, Equatable {
    let sessionId: String
    let update: ACPSessionUpdate
}

enum ACPSessionUpdate: Codable, Equatable {
    case userMessageChunk(ACPContentBlock)
    case agentMessageChunk(ACPContentBlock)
    case agentThoughtChunk(ACPContentBlock)
    case toolCall(ACPToolCallPayload)
    case toolCallUpdate(ACPToolCallUpdate)
    case plan([ACPPlanEntry])
    case availableModelsUpdate([ACPModelInfo])
    case currentModeUpdate(modeId: String)
    case currentModelUpdate(modelId: String)
    case sessionConfigOptionsUpdate([ACPConfigOption])
    case availableCommandsUpdate([ACPPromptSuggestion])
    case unknown(String)

    private enum Keys: String, CodingKey {
        case sessionUpdate, content, availableModels, modeId, modelId,
             entries, availableCommands, configOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "user_message_chunk":   self = .userMessageChunk(try c.decode(ACPContentBlock.self, forKey: .content))
        case "agent_message_chunk":  self = .agentMessageChunk(try c.decode(ACPContentBlock.self, forKey: .content))
        case "agent_thought_chunk":  self = .agentThoughtChunk(try c.decode(ACPContentBlock.self, forKey: .content))
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
        try c.encode(b, forKey: .content)
        case .agentMessageChunk(let b): try c.encode("agent_message_chunk", forKey: .sessionUpdate)
        try c.encode(b, forKey: .content)
        case .agentThoughtChunk(let b): try c.encode("agent_thought_chunk", forKey: .sessionUpdate)
        try c.encode(b, forKey: .content)
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
        case .availableCommandsUpdate: break // not produced by us
        case .toolCall, .toolCallUpdate, .unknown: break
        }
    }
}

struct ACPToolCallPayload: Codable, Equatable {
    let toolCallId: String
    let title: String
    let kind: String?
    let status: String
    let content: [ACPContentBlock]?
    let locations: [ACPToolLocation]?
    let rawInput: AnyCodable?
    let rawOutput: AnyCodable?
}

struct ACPToolCallUpdate: Codable, Equatable {
    let toolCallId: String
    let status: String?
    let content: [ACPContentBlock]?
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
