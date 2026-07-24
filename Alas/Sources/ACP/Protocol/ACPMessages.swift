import CoreFoundation
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
    let auth: ACPAuthCapabilities
    let session: ACPSessionCapabilities
    let elicitation: ACPElicitationCapabilities?
    let meta: ACPClientCapabilitiesMeta

    init(
        fs: ACPFsCapabilities,
        terminal: Bool,
        auth: ACPAuthCapabilities = .init(terminal: true),
        session: ACPSessionCapabilities = .booleanConfigOptions,
        elicitation: ACPElicitationCapabilities? = .full,
        meta: ACPClientCapabilitiesMeta = .terminalAuth
    ) {
        self.fs = fs
        self.terminal = terminal
        self.auth = auth
        self.session = session
        self.elicitation = elicitation
        self.meta = meta
    }

    enum CodingKeys: String, CodingKey {
        case fs, terminal, auth, session, elicitation
        case meta = "_meta"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fs = try c.decode(ACPFsCapabilities.self, forKey: .fs)
        terminal = try c.decode(Bool.self, forKey: .terminal)
        auth = try c.decodeIfPresent(ACPAuthCapabilities.self, forKey: .auth)
            ?? .init(terminal: false)
        session = try c.decodeIfPresent(ACPSessionCapabilities.self, forKey: .session)
            ?? .init(configOptions: .init(boolean: nil))
        elicitation = try c.decodeIfPresent(ACPElicitationCapabilities.self, forKey: .elicitation)
        meta = try c.decodeIfPresent(ACPClientCapabilitiesMeta.self, forKey: .meta)
            ?? .init(terminalAuth: false)
    }

    struct ACPFsCapabilities: Codable, Equatable {
        let readTextFile: Bool
        let writeTextFile: Bool
    }
}

struct ACPSessionCapabilities: Codable, Equatable {
    static let booleanConfigOptions = ACPSessionCapabilities(
        configOptions: .init(boolean: .init()))

    let configOptions: ConfigOptions

    init(configOptions: ConfigOptions = .init(boolean: nil)) {
        self.configOptions = configOptions
    }

    enum CodingKeys: String, CodingKey {
        case configOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configOptions = try c.decodeIfPresent(ConfigOptions.self, forKey: .configOptions)
            ?? .init(boolean: nil)
    }

    struct ConfigOptions: Codable, Equatable {
        let boolean: EmptyObject?
    }
}

struct EmptyObject: Codable, Equatable {}

struct ACPAuthCapabilities: Codable, Equatable {
    let terminal: Bool

    init(terminal: Bool) {
        self.terminal = terminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
    }
}

struct ACPClientCapabilitiesMeta: Codable, Equatable {
    static let terminalAuth = ACPClientCapabilitiesMeta(
        terminalAuth: true,
        parameterizedModelPicker: true)

    let terminalAuth: Bool
    let parameterizedModelPicker: Bool

    init(terminalAuth: Bool, parameterizedModelPicker: Bool = false) {
        self.terminalAuth = terminalAuth
        self.parameterizedModelPicker = parameterizedModelPicker
    }

    enum CodingKeys: String, CodingKey {
        case terminalAuth = "terminal-auth"
        case parameterizedModelPicker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalAuth = try c.decodeIfPresent(Bool.self, forKey: .terminalAuth) ?? false
        parameterizedModelPicker = try c.decodeIfPresent(Bool.self, forKey: .parameterizedModelPicker) ?? false
    }
}

// MARK: - authenticate

struct ACPAuthenticateParams: Codable, Equatable {
    let methodId: String
}

struct ACPInitializeResult: Codable, Equatable {
    let protocolVersion: Int
    let agentCapabilities: ACPAgentCapabilities?
    let authMethods: [ACPAuthMethod]

    init(
        protocolVersion: Int,
        agentCapabilities: ACPAgentCapabilities?,
        authMethods: [ACPAuthMethod]
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion, agentCapabilities, authMethods
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        agentCapabilities = try c.decodeIfPresent(ACPAgentCapabilities.self, forKey: .agentCapabilities)
        authMethods = try c.decodeIfPresent([ACPAuthMethod].self, forKey: .authMethods) ?? []
    }

    struct ACPAgentCapabilities: Codable, Equatable {
        let promptCapabilities: ACPPromptCapabilities?
        let loadSession: Bool
        let sessionCapabilities: ACPAgentSessionCapabilities
        let mcpCapabilities: ACPMCPServerCapabilities

        init(
            promptCapabilities: ACPPromptCapabilities? = nil,
            loadSession: Bool = false,
            sessionCapabilities: ACPAgentSessionCapabilities = .init(),
            mcpCapabilities: ACPMCPServerCapabilities = .init()
        ) {
            self.promptCapabilities = promptCapabilities
            self.loadSession = loadSession
            self.sessionCapabilities = sessionCapabilities
            self.mcpCapabilities = mcpCapabilities
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            promptCapabilities = try c.decodeIfPresent(ACPPromptCapabilities.self, forKey: .promptCapabilities)
            loadSession = try c.decodeIfPresent(Bool.self, forKey: .loadSession) ?? false
            sessionCapabilities = try c.decodeIfPresent(
                ACPAgentSessionCapabilities.self,
                forKey: .sessionCapabilities
            ) ?? .init()
            mcpCapabilities = try c.decodeIfPresent(ACPMCPServerCapabilities.self, forKey: .mcpCapabilities) ?? .init()
        }
    }

    struct ACPAgentSessionCapabilities: Codable, Equatable {
        let list: EmptyObject?
        let resume: EmptyObject?
        let fork: EmptyObject?

        init(list: EmptyObject? = nil, resume: EmptyObject? = nil, fork: EmptyObject? = nil) {
            self.list = list
            self.resume = resume
            self.fork = fork
        }

        var supportsList: Bool { list != nil }
        var supportsResume: Bool { resume != nil }
        var supportsFork: Bool { fork != nil }
    }
    struct ACPPromptCapabilities: Codable, Equatable {
        let image: Bool
        let audio: Bool
        let embeddedContext: Bool

        init(image: Bool = false, audio: Bool = false, embeddedContext: Bool = false) {
            self.image = image
            self.audio = audio
            self.embeddedContext = embeddedContext
        }

        // ACP defines each prompt capability as defaulting to false when
        // omitted, so an agent advertising only `{ "image": true }` must still
        // decode (a non-optional `audio` or `embeddedContext` would otherwise
        // fail the whole initialize result and silently drop image support).
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            image = try c.decodeIfPresent(Bool.self, forKey: .image) ?? false
            audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? false
            embeddedContext = try c.decodeIfPresent(Bool.self, forKey: .embeddedContext) ?? false
        }
    }
    struct ACPAuthMethod: Codable, Equatable {
        let id: String
        let name: String
        let description: String?
        let kind: Kind
        let args: [String]?
        let env: [String: String]?
        let vars: [ACPAuthEnvVar]?
        let meta: Meta?

        var terminalAuth: TerminalAuthMeta? { meta?.terminalAuth }

        init(
            id: String,
            name: String,
            description: String? = nil,
            kind: Kind = .agent,
            args: [String]? = nil,
            env: [String: String]? = nil,
            vars: [ACPAuthEnvVar]? = nil,
            meta: Meta? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.kind = kind
            self.args = args
            self.env = env
            self.vars = vars
            self.meta = meta
        }

        enum CodingKeys: String, CodingKey {
            case id, name, description, args, env, vars
            case kind = "type"
            case meta = "_meta"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .agent
            args = try c.decodeIfPresent([String].self, forKey: .args)
            env = try c.decodeIfPresent([String: String].self, forKey: .env)
            vars = try c.decodeIfPresent([ACPAuthEnvVar].self, forKey: .vars)
            meta = try c.decodeIfPresent(Meta.self, forKey: .meta)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(args, forKey: .args)
            try c.encodeIfPresent(env, forKey: .env)
            try c.encodeIfPresent(vars, forKey: .vars)
            try c.encodeIfPresent(meta, forKey: .meta)
        }

        enum Kind: Codable, Equatable {
            case agent
            case terminal
            case envVar
            case unknown(String)

            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                switch try c.decode(String.self) {
                case "agent": self = .agent
                case "terminal": self = .terminal
                case "env_var": self = .envVar
                case let value: self = .unknown(value)
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .agent: try c.encode("agent")
                case .terminal: try c.encode("terminal")
                case .envVar: try c.encode("env_var")
                case .unknown(let value): try c.encode(value)
                }
            }
        }

        struct Meta: Codable, Equatable {
            let terminalAuth: TerminalAuthMeta?

            enum CodingKeys: String, CodingKey {
                case terminalAuth = "terminal-auth"
            }
        }

        struct TerminalAuthMeta: Codable, Equatable {
            let command: String?
            let args: [String]?
            let label: String?
        }

        struct ACPAuthEnvVar: Codable, Equatable {
            let name: String
            let label: String?
            let optional: Bool?
            let secret: Bool?
        }
    }
}

/// Type-erased Codable used for `JSONRPCError.data` and `_meta` fields.
/// It only carries values that are JSON-compatible and safe to move across
/// actor boundaries as immutable payload data.
struct AnyCodable: Codable, Equatable, Hashable, @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }

    private enum CanonicalValue: Equatable, Hashable, Encodable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([CanonicalValue])
        case object([CanonicalObjectMember])

        func encode(to encoder: Encoder) throws {
            switch self {
            case .null:
                var c = encoder.singleValueContainer()
                try c.encodeNil()
            case .bool(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .int(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .double(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .string(let value):
                var c = encoder.singleValueContainer()
                try c.encode(value)
            case .array(let values):
                var c = encoder.unkeyedContainer()
                for value in values { try c.encode(value) }
            case .object(let members):
                var c = encoder.container(keyedBy: CanonicalObjectCodingKey.self)
                for member in members {
                    try c.encode(member.value, forKey: .init(member.key))
                }
            }
        }
    }

    private struct CanonicalObjectCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct CanonicalObjectMember: Equatable, Hashable {
        let key: String
        let value: CanonicalValue
    }

    private var canonicalValue: CanonicalValue {
        return AnyCodable.canonicalize(value)
    }

    private static func canonicalize(_ value: Any) -> CanonicalValue {
        if let value = value as? AnyCodable { return value.canonicalValue }
        if value is NSNull { return .null }
        if let value = value as? NSNumber {
            let cfValue = value as CFNumber
            if CFGetTypeID(cfValue) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            if CFNumberIsFloatType(cfValue) {
                return .double(value.doubleValue)
            }
            return .int(value.intValue)
        }
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .int(value) }
        if let value = value as? Double { return .double(value) }
        if let value = value as? String { return .string(value) }
        if let value = value as? [AnyCodable] {
            return .array(value.map { $0.canonicalValue })
        }
        if let value = value as? [String: AnyCodable] {
            return .object(value
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    CanonicalObjectMember(key: key, value: value.canonicalValue)
                })
        }
        if let value = value as? [Any] {
            return .array(value.map { AnyCodable.canonicalize($0) })
        }
        if let value = value as? NSArray {
            return .array(value.map { AnyCodable.canonicalize($0) })
        }
        if let value = value as? [String: Any] {
            return .object(value
                .sorted(by: { $0.key < $1.key })
                .map { key, value in
                    CanonicalObjectMember(key: key, value: AnyCodable.canonicalize(value))
                })
        }
        if let value = value as? NSDictionary {
            var members: [CanonicalObjectMember] = []
            for (rawKey, rawValue) in value {
                guard let key = rawKey as? String else { return .null }
                members.append(CanonicalObjectMember(key: key, value: canonicalize(rawValue)))
            }
            return .object(members.sorted(by: { $0.key < $1.key }))
        }
        return .null
    }

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
        try c.encode(canonicalValue)
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.canonicalValue == rhs.canonicalValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalValue)
    }
}

// MARK: - session/new

struct ACPSessionNewParams: Codable, Equatable {
    let cwd: String
    let mcpServers: [ACPMCPServer]
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
    let hint: String?

    init(command: String, description: String?, hint: String? = nil) {
        self.command = command
        self.description = description
        self.hint = hint
    }
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
        sessionId = (try? c.decode(String.self, forKey: .sessionId)) ?? ""

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

    func withSessionId(_ sessionId: String) -> ACPSessionNewResult {
        ACPSessionNewResult(
            sessionId: sessionId,
            availableModels: availableModels,
            availableModes: availableModes,
            currentModel: currentModel,
            currentMode: currentMode,
            promptSuggestions: promptSuggestions,
            configOptions: configOptions
        )
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
    let mcpServers: [ACPMCPServer]
}

// MARK: - session/list + session/resume + session/fork

struct ACPSessionListParams: Codable, Equatable {
    let cwd: String?
    let cursor: String?
}

struct ACPSessionListResult: Codable, Equatable {
    let sessions: [ACPAgentSessionInfo]
    let nextCursor: String?

    init(sessions: [ACPAgentSessionInfo], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

struct ACPAgentSessionInfo: Codable, Equatable, Identifiable {
    var id: String { sessionId }

    let sessionId: String
    let cwd: String
    let title: String?
    let updatedAt: String?
    let additionalDirectories: [String]?

    init(
        sessionId: String,
        cwd: String,
        title: String? = nil,
        updatedAt: String? = nil,
        additionalDirectories: [String]? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = title
        self.updatedAt = updatedAt
        self.additionalDirectories = additionalDirectories
    }
}

typealias ACPSessionResumeParams = ACPSessionLoadParams
typealias ACPSessionForkParams = ACPSessionLoadParams

// MARK: - session/close

struct ACPSessionCloseParams: Codable, Equatable {
    let sessionId: String
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

enum ACPContentBlock: Codable, Equatable, Sendable {
    case text(String)
    case resourceLink(uri: String, name: String?)
    case image(data: String?, uri: String?, mimeType: String?)
    case resource(uri: String, mimeType: String?, text: String)

    private enum Keys: String, CodingKey { case type, text, uri, name, mimeType, data, resource }
    private struct EmbeddedResource: Codable, Equatable, Sendable {
        let uri: String
        let mimeType: String?
        let text: String?
        let blob: String?

        private enum CodingKeys: String, CodingKey {
            case uri, mimeType, text, blob
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(uri, forKey: .uri)
            try c.encodeIfPresent(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(blob, forKey: .blob)
        }
    }

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
                data: try? c.decode(String.self, forKey: .data),
                uri: try? c.decode(String.self, forKey: .uri),
                mimeType: try? c.decode(String.self, forKey: .mimeType))
        case "resource":
            let resource = try c.decode(EmbeddedResource.self, forKey: .resource)
            if let text = resource.text {
                self = .resource(uri: resource.uri, mimeType: resource.mimeType, text: text)
            } else {
                self = .resourceLink(uri: resource.uri, name: URL(string: resource.uri)?.lastPathComponent)
            }
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
        case .image(let data, let uri, let mime):
            try c.encode("image", forKey: .type)
            try c.encodeIfPresent(data, forKey: .data)
            try c.encodeIfPresent(uri, forKey: .uri)
            try c.encodeIfPresent(mime, forKey: .mimeType)
        case .resource(let uri, let mime, let text):
            try c.encode("resource", forKey: .type)
            try c.encode(
                EmbeddedResource(uri: uri, mimeType: mime, text: text, blob: nil),
                forKey: .resource)
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
