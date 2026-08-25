import Foundation

struct ACPSessionUpdateParams: Codable, Equatable {
    let sessionId: String
    let update: ACPSessionUpdate
    let durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement?

    init(
        sessionId: String,
        update: ACPSessionUpdate,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        self.sessionId = sessionId
        self.update = update
        self.durableConsumptionAcknowledgement = durableConsumptionAcknowledgement
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, update
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        update = try container.decode(ACPSessionUpdate.self, forKey: .update)
        durableConsumptionAcknowledgement = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(update, forKey: .update)
    }

    static func == (lhs: ACPSessionUpdateParams, rhs: ACPSessionUpdateParams) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.update == rhs.update
    }
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
    case compactionUpdate(ACPCompactionUpdate)
    case compactionSummaryChunk(ACPCompactionSummaryChunk)
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
             entries, availableCommands, configOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .sessionUpdate)
        switch kind {
        case "user_message_chunk":
            self = .userMessageChunk(try ACPTextChunk(from: decoder))
        case "agent_message_chunk":
            self = .agentMessageChunk(try ACPTextChunk(from: decoder))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try ACPTextChunk(from: decoder))
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
            // Wire format:
            // `{ availableCommands: [{ name, description, input: { hint } }] }`.
            let raw = (try? c.decode([ACPAvailableCommand].self, forKey: .availableCommands)) ?? []
            self = .availableCommandsUpdate(raw.map {
                let cmd = $0.name.hasPrefix("/") ? $0.name : "/" + $0.name
                return ACPPromptSuggestion(
                    command: cmd, description: $0.description, hint: $0.input?.hint)
            })
        case "usage_update":
            self = .usageUpdate(try ACPUsageInfo(from: decoder))
        case "session_info_update":
            self = .sessionInfoUpdate(try ACPSessionInfoUpdate(from: decoder))
        case "compaction_update":
            self = .compactionUpdate(try ACPCompactionUpdate(from: decoder))
        case "compaction_summary_chunk":
            self = .compactionSummaryChunk(try ACPCompactionSummaryChunk(from: decoder))
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
        let input: Input?
        struct Input: Codable { let hint: String }
        enum CodingKeys: String, CodingKey { case name, description, input }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            input = try? c.decodeIfPresent(Input.self, forKey: .input)
        }
    }

    func encode(to encoder: Encoder) throws {
        // Encoding not required for v1 (we only receive these). Implement when needed.
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .userMessageChunk(let b):
            try c.encode("user_message_chunk", forKey: .sessionUpdate)
            try b.encodeFields(to: encoder)
        case .agentMessageChunk(let b):
            try c.encode("agent_message_chunk", forKey: .sessionUpdate)
            try b.encodeFields(to: encoder)
        case .agentThoughtChunk(let b):
            try c.encode("agent_thought_chunk", forKey: .sessionUpdate)
            try b.encodeFields(to: encoder)
        case .plan(let e):
            try c.encode("plan", forKey: .sessionUpdate)
            try c.encode(e, forKey: .entries)
        case .availableModelsUpdate(let m):
            try c.encode("available_models_update", forKey: .sessionUpdate)
            try c.encode(m, forKey: .availableModels)
        case .currentModeUpdate(let m):
            try c.encode("current_mode_update", forKey: .sessionUpdate)
            try c.encode(m, forKey: .modeId)
        case .currentModelUpdate(let m):
            try c.encode("current_model_update", forKey: .sessionUpdate)
            try c.encode(m, forKey: .modelId)
        case .sessionConfigOptionsUpdate(let opts):
            try c.encode("session_config_options_update", forKey: .sessionUpdate)
            try c.encode(opts, forKey: .configOptions)
        case .sessionInfoUpdate(let info):
            try c.encode("session_info_update", forKey: .sessionUpdate)
            try info.encodeFields(to: encoder)
        case .availableCommandsUpdate:
            break
        case .toolCall, .toolCallUpdate, .usageUpdate, .compactionUpdate,
             .compactionSummaryChunk, .unknown:
            break
        }
    }
}

enum ACPMessagePhase: String, Codable, Equatable, Sendable {
    case commentary
    case finalAnswer = "final_answer"

    static func codexPhase(in metadata: AnyCodable?) -> ACPMessagePhase? {
        guard let metadata = metadata?.value as? [String: AnyCodable],
              let codex = metadata["codex"]?.value as? [String: AnyCodable],
              let value = codex["phase"]?.value as? String
        else { return nil }
        return ACPMessagePhase(rawValue: value)
    }
}

/// Experimental ACP compaction lifecycle update. Optional fields decode
/// defensively because this wire format is still evolving.
struct ACPCompactionUpdate: Codable, Equatable {
    let compactionId: String
    let status: String
    let summary: [ACPContentBlock]?
    let summaryWasProvided: Bool
    let summaryWasNull: Bool
    let error: String?
    let errorWasProvided: Bool
    let errorWasNull: Bool
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case compactionId, status, summary, error
        case metadata = "_meta"
    }

    init(
        compactionId: String,
        status: String,
        summary: [ACPContentBlock]? = nil,
        error: String? = nil,
        metadata: AnyCodable? = nil
    ) {
        self.compactionId = compactionId
        self.status = status
        self.summary = summary
        self.summaryWasProvided = summary != nil
        self.summaryWasNull = false
        self.error = error
        self.errorWasProvided = error != nil
        self.errorWasNull = false
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compactionId = try c.decode(String.self, forKey: .compactionId)
        status = try c.decode(String.self, forKey: .status)
        summaryWasProvided = c.contains(.summary)
        summaryWasNull = summaryWasProvided ? try c.decodeNil(forKey: .summary) : false
        summary = summaryWasNull ? nil : try? c.decodeIfPresent([ACPContentBlock].self, forKey: .summary)
        errorWasProvided = c.contains(.error)
        errorWasNull = errorWasProvided ? try c.decodeNil(forKey: .error) : false
        error = errorWasNull ? nil : try? c.decodeIfPresent(String.self, forKey: .error)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

/// Experimental ACP chunk appended to an in-progress compaction summary.
struct ACPCompactionSummaryChunk: Codable, Equatable {
    let compactionId: String
    let content: ACPContentBlock
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case compactionId, content
        case metadata = "_meta"
    }

    init(compactionId: String, content: ACPContentBlock, metadata: AnyCodable? = nil) {
        self.compactionId = compactionId
        self.content = content
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compactionId = try c.decode(String.self, forKey: .compactionId)
        content = try c.decode(ACPContentBlock.self, forKey: .content)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

struct ACPTextChunk: Codable, Equatable {
    let messageId: String?
    let content: ACPContentBlock
    let metadata: AnyCodable?

    var phase: ACPMessagePhase? {
        ACPMessagePhase.codexPhase(in: metadata)
    }

    init(messageId: String? = nil, content: ACPContentBlock, metadata: AnyCodable? = nil) {
        self.messageId = messageId
        self.content = content
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case messageId, content
        case metadata = "_meta"
    }

    func encodeFields(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(messageId, forKey: .messageId)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

struct ACPSessionInfoUpdate: Codable, Equatable {
    let title: ACPStringFieldUpdate
    let updatedAt: String?
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case title, updatedAt
        case metadata = "_meta"
    }

    init(
        title: ACPStringFieldUpdate = .absent,
        updatedAt: String? = nil,
        metadata: AnyCodable? = nil
    ) {
        self.title = title
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    init(title: String?, updatedAt: String? = nil, metadata: AnyCodable? = nil) {
        self.title = title.map(ACPStringFieldUpdate.value) ?? .absent
        self.updatedAt = updatedAt
        self.metadata = metadata
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
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }

    func encode(to encoder: Encoder) throws {
        try encodeFields(to: encoder)
    }

    func encodeFields(to encoder: Encoder) throws {
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
        try c.encodeIfPresent(metadata, forKey: .metadata)
    }
}

enum ACPStringFieldUpdate: Equatable {
    case absent
    case null
    case value(String)
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
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput
        case metadata = "_meta"
    }

    init(
        toolCallId: String,
        title: String,
        kind: String?,
        status: String,
        content: [ACPToolCallContent]? = nil,
        locations: [ACPToolLocation]? = nil,
        rawInput: AnyCodable? = nil,
        rawOutput: AnyCodable? = nil,
        metadata: AnyCodable? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.metadata = metadata
    }
}

struct ACPToolCallUpdate: Codable, Equatable {
    let toolCallId: String
    let title: String?
    let status: String?
    let locations: [ACPToolLocation]?
    let content: [ACPToolCallContent]?
    let rawOutput: AnyCodable?
    let rawInput: AnyCodable?
    let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, status, locations, content, rawInput, rawOutput
        case metadata = "_meta"
    }

    init(
        toolCallId: String,
        status: String? = nil,
        content: [ACPToolCallContent]? = nil,
        rawOutput: AnyCodable? = nil,
        title: String? = nil,
        locations: [ACPToolLocation]? = nil,
        rawInput: AnyCodable? = nil,
        metadata: AnyCodable? = nil
    ) {
        self.toolCallId = toolCallId
        self.title = title
        self.status = status
        self.locations = locations
        self.content = content
        self.rawOutput = rawOutput
        self.rawInput = rawInput
        self.metadata = metadata
    }
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
