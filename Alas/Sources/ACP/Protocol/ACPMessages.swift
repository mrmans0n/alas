import Foundation

/// A generic JSON-RPC 2.0 envelope. Shared by every ACP wire type.
struct JSONRPCEnvelope<Payload: Codable>: Codable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String?
    let params: Payload?
    let result: Payload?
    let error: JSONRPCError?

    init(id: JSONRPCID?, method: String, params: Payload?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.result = nil
        self.error = nil
    }
}

enum JSONRPCID: Codable, Equatable, Hashable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n)
        return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

struct JSONRPCError: Codable, Equatable, Error, Sendable {
    let code: Int
    let message: String
    let data: AnyCodable?
}

// MARK: - initialize

struct ACPInitializeParams: Codable, Equatable {
    let protocolVersion: Int
    let clientCapabilities: ACPClientCapabilities
}

struct ACPClientCapabilities: Codable, Equatable {
    let fs: ACPFsCapabilities
    /// Agents must check `clientCapabilities.terminal` during initialize
    /// and only invoke `terminal/*` methods when it is true (ACP spec).
    let terminal: Bool

    struct ACPFsCapabilities: Codable, Equatable {
        let readTextFile: Bool
        let writeTextFile: Bool
    }
}

struct ACPInitializeResult: Codable, Equatable {
    let protocolVersion: Int
    let agentCapabilities: ACPAgentCapabilities?
    let authMethods: [ACPAuthMethod]

    struct ACPAgentCapabilities: Codable, Equatable {
        let promptCapabilities: ACPPromptCapabilities?
    }
    struct ACPPromptCapabilities: Codable, Equatable {
        let image: Bool
        let audio: Bool
    }
    struct ACPAuthMethod: Codable, Equatable {
        let id: String
        let name: String
    }
}

/// Type-erased Codable used for `JSONRPCError.data` and `_meta` fields.
struct AnyCodable: Codable, Equatable {
    let value: Any
    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self.value = NSNull()
        return }
        if let v = try? c.decode(Bool.self) { self.value = v
        return }
        if let v = try? c.decode(Int.self) { self.value = v
        return }
        if let v = try? c.decode(Double.self) { self.value = v
        return }
        if let v = try? c.decode(String.self) { self.value = v
        return }
        if let v = try? c.decode([AnyCodable].self) { self.value = v
        return }
        if let v = try? c.decode([String: AnyCodable].self) { self.value = v
        return }
        self.value = NSNull()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
}

// MARK: - session/new

struct ACPSessionNewParams: Codable, Equatable {
    let cwd: String
    let mcpServers: [ACPMCPServer]

    struct ACPMCPServer: Codable, Equatable {
        let name: String
        let command: String
        let args: [String]
    }
}

struct ACPModelInfo: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    // ACP wire format uses `modelId` for the id; accept both shapes.
    enum CodingKeys: String, CodingKey { case id, modelId, name, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .modelId) {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .modelId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

struct ACPModeInfo: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
    enum CodingKeys: String, CodingKey { case id, modeId, name, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .modeId) {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

struct ACPPromptSuggestion: Codable, Equatable, Hashable {
    let command: String
    let description: String?
}

struct ACPSessionNewResult: Codable, Equatable {
    let sessionId: String
    let availableModels: [ACPModelInfo]
    let availableModes: [ACPModeInfo]
    let currentModel: String?
    let currentMode: String?
    let promptSuggestions: [ACPPromptSuggestion]
    let configOptions: [ACPConfigOption]

    enum CodingKeys: String, CodingKey {
        case sessionId, availableModels, availableModes, currentModel, currentMode, promptSuggestions, configOptions
        case models, modes
    }

    // We only ever receive this type — encoding is not used in production.
    // Provide a flat encode against the CodingKeys we read into so the
    // synthesized Codable contract holds.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(availableModels, forKey: .availableModels)
        try c.encode(availableModes, forKey: .availableModes)
        try c.encodeIfPresent(currentModel, forKey: .currentModel)
        try c.encodeIfPresent(currentMode, forKey: .currentMode)
        try c.encode(promptSuggestions, forKey: .promptSuggestions)
        try c.encode(configOptions, forKey: .configOptions)
    }

    init(
        sessionId: String,
        availableModels: [ACPModelInfo],
        availableModes: [ACPModeInfo],
        currentModel: String?,
        currentMode: String?,
        promptSuggestions: [ACPPromptSuggestion],
        configOptions: [ACPConfigOption] = []
    ) {
        self.sessionId = sessionId
        self.availableModels = availableModels
        self.availableModes = availableModes
        self.currentModel = currentModel
        self.currentMode = currentMode
        self.promptSuggestions = promptSuggestions
        self.configOptions = configOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)

        // ACP v1 nests these as `models: { availableModels, currentModelId }`
        // and `modes: { availableModes, currentModeId }`. Older drafts used
        // the flat shape we still accept as a fallback.
        if let modelsBlock = try? c.decode(ACPModelsBlock.self, forKey: .models) {
            availableModels = modelsBlock.availableModels
            currentModel = modelsBlock.currentModelId
        } else {
            availableModels = (try? c.decode([ACPModelInfo].self, forKey: .availableModels)) ?? []
            currentModel = try? c.decode(String.self, forKey: .currentModel)
        }

        if let modesBlock = try? c.decode(ACPModesBlock.self, forKey: .modes) {
            availableModes = modesBlock.availableModes
            currentMode = modesBlock.currentModeId
        } else {
            availableModes = (try? c.decode([ACPModeInfo].self, forKey: .availableModes)) ?? []
            currentMode = try? c.decode(String.self, forKey: .currentMode)
        }

        promptSuggestions = (try? c.decode([ACPPromptSuggestion].self, forKey: .promptSuggestions)) ?? []
        configOptions = (try? c.decode([ACPConfigOption].self, forKey: .configOptions)) ?? []
    }
}

private struct ACPModelsBlock: Decodable {
    let currentModelId: String?
    let availableModels: [ACPModelInfo]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentModelId = try? c.decode(String.self, forKey: .currentModelId)
        availableModels = (try? c.decode([ACPModelInfo].self, forKey: .availableModels)) ?? []
    }
    enum CodingKeys: String, CodingKey { case currentModelId, availableModels }
}

private struct ACPModesBlock: Decodable {
    let currentModeId: String?
    let availableModes: [ACPModeInfo]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentModeId = try? c.decode(String.self, forKey: .currentModeId)
        availableModes = (try? c.decode([ACPModeInfo].self, forKey: .availableModes)) ?? []
    }
    enum CodingKeys: String, CodingKey { case currentModeId, availableModes }
}

// MARK: - session/load

struct ACPSessionLoadParams: Codable, Equatable {
    let cwd: String
    let sessionId: String
    let mcpServers: [ACPSessionNewParams.ACPMCPServer]
}

// MARK: - session/cancel

struct ACPSessionCancelParams: Codable, Equatable {
    let sessionId: String
}

// MARK: - session/setMode + setModel

struct ACPSessionSetModeParams: Codable, Equatable {
    let sessionId: String
    let modeId: String
}

struct ACPSessionSetModelParams: Codable, Equatable {
    let sessionId: String
    let modelId: String
}

// MARK: - session/prompt

struct ACPSessionPromptParams: Codable, Equatable {
    let sessionId: String
    let prompt: [ACPContentBlock]
}

enum ACPContentBlock: Codable, Equatable {
    case text(String)
    case resourceLink(uri: String, name: String?)
    case image(uri: String, mimeType: String?)

    private enum Keys: String, CodingKey { case type, text, uri, name, mimeType }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "resource_link":
            self = .resourceLink(
                uri: try c.decode(String.self, forKey: .uri),
                name: try? c.decode(String.self, forKey: .name))
        case "image":
            self = .image(
                uri: try c.decode(String.self, forKey: .uri),
                mimeType: try? c.decode(String.self, forKey: .mimeType))
        default:
            self = .text("")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .resourceLink(let uri, let name):
            try c.encode("resource_link", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(name, forKey: .name)
        case .image(let uri, let mime):
            try c.encode("image", forKey: .type)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(mime, forKey: .mimeType)
        }
    }
}

/// Per the ACP spec, a `tool_call.content` entry is a tagged union, not a
/// plain content block. The wrapper carries either a regular content
/// block, a file diff, or a terminal reference. Decoding the inner shape
/// directly (which our older code did) silently drops every real tool
/// result because they all arrive as `{"type": "content", ...}` and miss
/// `ACPContentBlock`'s text/resource_link/image discriminator.
enum ACPToolCallContent: Codable, Equatable {
    case content(ACPContentBlock)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
    /// Forward-compatibility bucket so a future spec variant doesn't get
    /// misdecoded as empty text (the previous bug pattern).
    case unknown

    private enum Keys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "content":
            self = .content(try c.decode(ACPContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(
                path: try c.decode(String.self, forKey: .path),
                oldText: try? c.decode(String.self, forKey: .oldText),
                newText: try c.decode(String.self, forKey: .newText))
        case "terminal":
            self = .terminal(terminalId: try c.decode(String.self, forKey: .terminalId))
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .content(let b):
            try c.encode("content", forKey: .type)
            try c.encode(b, forKey: .content)
        case .diff(let path, let old, let new):
            try c.encode("diff", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(old, forKey: .oldText)
            try c.encode(new, forKey: .newText)
        case .terminal(let id):
            try c.encode("terminal", forKey: .type)
            try c.encode(id, forKey: .terminalId)
        case .unknown:
            // Unknown variants are receive-only forward-compat; they
            // never round-trip, so encoding them as a discriminator-only
            // object is acceptable.
            try c.encode("unknown", forKey: .type)
        }
    }
}
