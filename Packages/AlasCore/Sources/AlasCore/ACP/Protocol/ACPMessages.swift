import CoreFoundation
import Foundation

/// A generic JSON-RPC 2.0 envelope. Shared by every ACP wire type.
public struct JSONRPCEnvelope<Payload: Codable>: Codable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String?
    public let params: Payload?
    public let result: Payload?
    public let error: JSONRPCError?

    public init(id: JSONRPCID?, method: String, params: Payload?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
        self.result = nil
        self.error = nil
    }
}

public enum JSONRPCID: Codable, Equatable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n)
        return }
        self = .string(try c.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

public struct JSONRPCError: Codable, Equatable, Error, Sendable {
    public let code: Int
    public let message: String
    public let data: AnyCodable?

    public init(code: Int, message: String, data: AnyCodable?) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - initialize

public struct ACPInitializeParams: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let clientCapabilities: ACPClientCapabilities

    public init(protocolVersion: Int, clientCapabilities: ACPClientCapabilities) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
    }
}

public struct ACPClientCapabilities: Codable, Equatable, Sendable {
    public let fs: ACPFsCapabilities
    /// Agents must check `clientCapabilities.terminal` during initialize
    /// and only invoke `terminal/*` methods when it is true (ACP spec).
    public let terminal: Bool
    public let auth: ACPAuthCapabilities
    public let session: ACPSessionCapabilities
    public let elicitation: ACPElicitationCapabilities?
    /// Native subagent (child session) support. `{}` opts in; agents that
    /// don't know the key ignore it and keep folding subagents into an
    /// opaque tool call, exactly as before.
    public let subagents: EmptyObject?
    public let meta: ACPClientCapabilitiesMeta

    public init(
        fs: ACPFsCapabilities,
        terminal: Bool,
        auth: ACPAuthCapabilities = .init(terminal: true),
        session: ACPSessionCapabilities = .booleanConfigOptions,
        elicitation: ACPElicitationCapabilities? = .full,
        subagents: EmptyObject? = .init(),
        meta: ACPClientCapabilitiesMeta = .terminalAuth
    ) {
        self.fs = fs
        self.terminal = terminal
        self.auth = auth
        self.session = session
        self.elicitation = elicitation
        self.subagents = subagents
        self.meta = meta
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case fs, terminal, auth, session, elicitation, subagents
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fs = try c.decode(ACPFsCapabilities.self, forKey: .fs)
        terminal = try c.decode(Bool.self, forKey: .terminal)
        auth = try c.decodeIfPresent(ACPAuthCapabilities.self, forKey: .auth)
            ?? .init(terminal: false)
        session = try c.decodeIfPresent(ACPSessionCapabilities.self, forKey: .session)
            ?? .init(configOptions: .init(boolean: nil))
        elicitation = try c.decodeIfPresent(ACPElicitationCapabilities.self, forKey: .elicitation)
        subagents = try? c.decodeIfPresent(EmptyObject.self, forKey: .subagents)
        meta = try c.decodeIfPresent(ACPClientCapabilitiesMeta.self, forKey: .meta)
            ?? .init(terminalAuth: false)
    }

    public struct ACPFsCapabilities: Codable, Equatable, Sendable {
        public let readTextFile: Bool
        public let writeTextFile: Bool

        public init(readTextFile: Bool, writeTextFile: Bool) {
            self.readTextFile = readTextFile
            self.writeTextFile = writeTextFile
        }
    }
}

public struct ACPSessionCapabilities: Codable, Equatable, Sendable {
    public static let booleanConfigOptions = ACPSessionCapabilities(
        configOptions: .init(boolean: .init()),
        compaction: .init(),
        notices: .init())

    public let configOptions: ConfigOptions
    /// Experimental ACP context-compaction updates. `{}` advertises support.
    public let compaction: EmptyObject?
    /// Experimental ACP session notices (fire-and-forget `notice` updates).
    /// `{}` advertises support. Without it, agents fall back to stuffing
    /// out-of-band events into `agent_message_chunk`, polluting the transcript.
    public let notices: EmptyObject?

    public init(
        configOptions: ConfigOptions = .init(boolean: nil),
        compaction: EmptyObject? = nil,
        notices: EmptyObject? = nil
    ) {
        self.configOptions = configOptions
        self.compaction = compaction
        self.notices = notices
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case configOptions, compaction, notices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configOptions = try c.decodeIfPresent(ConfigOptions.self, forKey: .configOptions)
            ?? .init(boolean: nil)
        compaction = try? c.decodeIfPresent(EmptyObject.self, forKey: .compaction)
        notices = try? c.decodeIfPresent(EmptyObject.self, forKey: .notices)
    }

    public struct ConfigOptions: Codable, Equatable, Sendable {
        public let boolean: EmptyObject?

        public init(boolean: EmptyObject?) {
            self.boolean = boolean
        }
    }
}

public struct EmptyObject: Codable, Equatable, Sendable {
    public init() {
    }}

public enum ACPGoalAction: String, Codable, CaseIterable, Hashable, Sendable {
    case set
    case pause
    case resume
    case clear
}

public struct ACPGoalCapability: Codable, Equatable, Sendable {
    public let version: Int
    public let controlMethod: String
    public let actions: Set<ACPGoalAction>

    private enum CodingKeys: String, CodingKey {
        case version, controlMethod, actions
    }

    public init(version: Int, controlMethod: String, actions: Set<ACPGoalAction>) {
        self.version = version
        self.controlMethod = controlMethod
        self.actions = actions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported ACP goal capability version \(version)"
            )
        }
        let method = try container.decode(String.self, forKey: .controlMethod)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !method.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .controlMethod,
                in: container,
                debugDescription: "ACP goal control method is empty"
            )
        }
        controlMethod = method
        actions = Set((try container.decodeIfPresent([String].self, forKey: .actions) ?? [])
            .compactMap(ACPGoalAction.init(rawValue:)))
    }
}

public struct ACPGoalControlParams: Encodable, Sendable {
    public let sessionId: String
    public let action: ACPGoalAction
    public let objective: String?

    public init(sessionId: String, action: ACPGoalAction, objective: String?) {
        self.sessionId = sessionId
        self.action = action
        self.objective = objective
    }
}

public enum ACPGoalControlError: LocalizedError, Sendable {
    case unavailable
    case unsupportedAction(ACPGoalAction)
    case objectiveRequired

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Goal controls are not available for this session."
        case .unsupportedAction(let action):
            "The agent does not support the \(action.rawValue) goal action."
        case .objectiveRequired:
            "Enter a goal objective."
        }
    }
}

public struct ACPAuthCapabilities: Codable, Equatable, Sendable {
    public let terminal: Bool

    public init(terminal: Bool) {
        self.terminal = terminal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
    }
}

public struct ACPAsyncTaskCapability: Codable, Equatable, Sendable {
    public let version: Int
    public let controlMethod: String
    public let actions: [String]

    public var supportsStop: Bool {
        version == 1 && controlMethod == "_session/async_task/stop" && actions.contains("stop")
    }

    public init(version: Int, controlMethod: String, actions: [String]) {
        self.version = version
        self.controlMethod = controlMethod
        self.actions = actions
    }
}

public struct ACPClientCapabilitiesMeta: Codable, Equatable, Sendable {
    public static let terminalAuth = ACPClientCapabilitiesMeta(
        terminalAuth: true,
        parameterizedModelPicker: true,
        openCodeChildSessionUpdates: true,
        asyncTasks: true,
        contextUsage: true)

    public let terminalAuth: Bool
    public let parameterizedModelPicker: Bool
    /// OpenCode v2's own spelling of the subagent opt-in. Without it OpenCode
    /// projects a child's updates into the parent session instead of sending
    /// `opencode/session/child_update`.
    public let openCodeChildSessionUpdates: Bool
    public let goal: EmptyObject
    public let asyncTasks: Bool
    /// Asks our Claude adapter fork to serve `_alas/context_usage`.
    public let contextUsage: Bool

    public init(
        terminalAuth: Bool,
        parameterizedModelPicker: Bool = false,
        openCodeChildSessionUpdates: Bool = false,
        goal: EmptyObject = .init(),
        asyncTasks: Bool = false,
        contextUsage: Bool = false
    ) {
        self.terminalAuth = terminalAuth
        self.parameterizedModelPicker = parameterizedModelPicker
        self.openCodeChildSessionUpdates = openCodeChildSessionUpdates
        self.goal = goal
        self.asyncTasks = asyncTasks
        self.contextUsage = contextUsage
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case contextUsage
        case terminalAuth = "terminal-auth"
        case parameterizedModelPicker
        case openCodeChildSessionUpdates = "opencode/child-session-updates"
        case goal
        case asyncTasks = "async-tasks"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalAuth = try c.decodeIfPresent(Bool.self, forKey: .terminalAuth) ?? false
        parameterizedModelPicker = try c.decodeIfPresent(Bool.self, forKey: .parameterizedModelPicker) ?? false
        openCodeChildSessionUpdates = try c.decodeIfPresent(
            Bool.self, forKey: .openCodeChildSessionUpdates) ?? false
        goal = try c.decodeIfPresent(EmptyObject.self, forKey: .goal) ?? .init()
        asyncTasks = try c.decodeIfPresent(Bool.self, forKey: .asyncTasks) ?? false
        contextUsage = try c.decodeIfPresent(Bool.self, forKey: .contextUsage) ?? false
    }
}

// MARK: - authenticate

public struct ACPAuthenticateParams: Codable, Equatable, Sendable {
    public let methodId: String

    public init(methodId: String) {
        self.methodId = methodId
    }
}

public struct ACPInitializeResult: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let agentCapabilities: ACPAgentCapabilities?
    public let authMethods: [ACPAuthMethod]
    /// The adapter's self-reported `agentInfo` (ACP `Implementation`).
    /// Optional on the wire; a malformed value is dropped, not fatal.
    public let agentInfo: ACPImplementationInfo?
    /// Extension capabilities live beside `agentCapabilities` on the wire.
    public let meta: Meta?

    public var supportsSteering: Bool {
        meta?.steering?.supported == true
    }

    public var supportsContextBreakdown: Bool {
        meta?.contextUsage?.supported == true
    }

    public init(
        protocolVersion: Int,
        agentCapabilities: ACPAgentCapabilities?,
        authMethods: [ACPAuthMethod],
        agentInfo: ACPImplementationInfo? = nil,
        meta: Meta? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.authMethods = authMethods
        self.agentInfo = agentInfo
        self.meta = meta
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case protocolVersion, agentCapabilities, authMethods, agentInfo
        case meta = "_meta"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        agentCapabilities = try c.decodeIfPresent(ACPAgentCapabilities.self, forKey: .agentCapabilities)
        authMethods = try c.decodeIfPresent([ACPAuthMethod].self, forKey: .authMethods) ?? []
        agentInfo = (try? c.decodeIfPresent(ACPImplementationInfo.self, forKey: .agentInfo)) ?? nil
        meta = try? c.decodeIfPresent(Meta.self, forKey: .meta)
    }

    public struct Meta: Codable, Equatable, Sendable {
        public let goal: ACPGoalCapability?
        public let asyncTasks: ACPAsyncTaskCapability?
        public let steering: Steering?
        /// `_alas/context_usage` extension (our Claude adapter fork).
        public let contextUsage: Steering?

        public enum CodingKeys: String, CodingKey, Sendable {
            case goal, steering, contextUsage
            case asyncTasks = "async-tasks"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            goal = try? c.decodeIfPresent(ACPGoalCapability.self, forKey: .goal)
            asyncTasks = try? c.decodeIfPresent(ACPAsyncTaskCapability.self, forKey: .asyncTasks)
            steering = try? c.decodeIfPresent(Steering.self, forKey: .steering)
            contextUsage = try? c.decodeIfPresent(Steering.self, forKey: .contextUsage)
        }

        public struct Steering: Codable, Equatable, Sendable {
            public let supported: Bool

            public init(supported: Bool) {
                self.supported = supported
            }
        }
    }

    public struct ACPAgentCapabilities: Codable, Equatable, Sendable {
        public let promptCapabilities: ACPPromptCapabilities?
        public let loadSession: Bool
        public let sessionCapabilities: ACPAgentSessionCapabilities
        public let mcpCapabilities: ACPMCPServerCapabilities
        public let providerCapabilities: EmptyObject?
        public let meta: Meta
        /// `true` when `_meta.authStatus` was present on `initialize`, i.e.
        /// the agent will push `_auth/status_update` notifications.
        public let advertisesAuthStatus: Bool

        public init(
            promptCapabilities: ACPPromptCapabilities? = nil,
            loadSession: Bool = false,
            sessionCapabilities: ACPAgentSessionCapabilities = .init(),
            mcpCapabilities: ACPMCPServerCapabilities = .init(),
            providerCapabilities: EmptyObject? = nil,
            meta: Meta = .init(),
            advertisesAuthStatus: Bool = false
        ) {
            self.promptCapabilities = promptCapabilities
            self.loadSession = loadSession
            self.sessionCapabilities = sessionCapabilities
            self.mcpCapabilities = mcpCapabilities
            self.providerCapabilities = providerCapabilities
            self.meta = meta
            self.advertisesAuthStatus = advertisesAuthStatus
        }

        public enum CodingKeys: String, CodingKey, Sendable {
            case promptCapabilities, loadSession, sessionCapabilities, mcpCapabilities
            case providerCapabilities = "providers"
            case meta = "_meta"
        }

        private enum MetaCodingKeys: String, CodingKey {
            case authStatus
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            promptCapabilities = try c.decodeIfPresent(ACPPromptCapabilities.self, forKey: .promptCapabilities)
            loadSession = try c.decodeIfPresent(Bool.self, forKey: .loadSession) ?? false
            sessionCapabilities = try c.decodeIfPresent(
                ACPAgentSessionCapabilities.self,
                forKey: .sessionCapabilities
            ) ?? .init()
            mcpCapabilities = try c.decodeIfPresent(ACPMCPServerCapabilities.self, forKey: .mcpCapabilities) ?? .init()
            providerCapabilities = try? c.decodeIfPresent(EmptyObject.self, forKey: .providerCapabilities)
            meta = (try? c.decodeIfPresent(Meta.self, forKey: .meta)) ?? .init()
            if let metaContainer = try? c.nestedContainer(keyedBy: MetaCodingKeys.self, forKey: .meta) {
                advertisesAuthStatus = (try? metaContainer.decodeIfPresent(
                    EmptyObject.self, forKey: .authStatus)) != nil
            } else {
                advertisesAuthStatus = false
            }
        }

        // `meta`/`advertisesAuthStatus` are inbound-only (derived from what
        // the agent's own `_meta` advertised); Alas never re-encodes an
        // agent's own `agentCapabilities`, so there's nothing meaningful to
        // write back for either and both are intentionally omitted here.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(promptCapabilities, forKey: .promptCapabilities)
            try c.encode(loadSession, forKey: .loadSession)
            try c.encode(sessionCapabilities, forKey: .sessionCapabilities)
            try c.encode(mcpCapabilities, forKey: .mcpCapabilities)
            try c.encodeIfPresent(providerCapabilities, forKey: .providerCapabilities)
        }

        /// Agent-side `_meta`. Only the keys Alas acts on are modelled;
        /// everything else is ignored rather than failing the handshake.
        public struct Meta: Decodable, Equatable, Sendable {
            public let openCodeChildSessionUpdates: Bool
            public let goal: ACPGoalCapability?

            public init(openCodeChildSessionUpdates: Bool = false, goal: ACPGoalCapability? = nil) {
                self.openCodeChildSessionUpdates = openCodeChildSessionUpdates
                self.goal = goal
            }

            public enum CodingKeys: String, CodingKey, Sendable {
                case openCodeChildSessionUpdates = "opencode/child-session-updates"
                case goal
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                let flag = try? c.decodeIfPresent(Bool.self, forKey: .openCodeChildSessionUpdates)
                openCodeChildSessionUpdates = (flag ?? nil) ?? false
                goal = (try? c.decodeIfPresent(ACPGoalCapability.self, forKey: .goal)) ?? nil
            }
        }
    }

    public struct ACPAgentSessionCapabilities: Codable, Equatable, Sendable {
        public let list: EmptyObject?
        public let resume: EmptyObject?
        public let fork: EmptyObject?
        public let delete: EmptyObject?
        public let close: EmptyObject?
        /// Native child sessions (`subagent_spawned` + child-scoped
        /// `session/update`), advertised by claude-agent-acp and codex-acp.
        public let subagents: EmptyObject?

        public init(
            list: EmptyObject? = nil,
            resume: EmptyObject? = nil,
            fork: EmptyObject? = nil,
            delete: EmptyObject? = nil,
            close: EmptyObject? = nil,
            subagents: EmptyObject? = nil
        ) {
            self.list = list
            self.resume = resume
            self.fork = fork
            self.delete = delete
            self.close = close
            self.subagents = subagents
        }

        public var supportsList: Bool { list != nil }
        public var supportsResume: Bool { resume != nil }
        public var supportsFork: Bool { fork != nil }
        public var supportsDelete: Bool { delete != nil }
        public var supportsClose: Bool { close != nil }
        public var supportsSubagents: Bool { subagents != nil }
    }
    public struct ACPPromptCapabilities: Codable, Equatable, Sendable {
        public let image: Bool
        public let audio: Bool
        public let embeddedContext: Bool

        public init(image: Bool = false, audio: Bool = false, embeddedContext: Bool = false) {
            self.image = image
            self.audio = audio
            self.embeddedContext = embeddedContext
        }

        // ACP defines each prompt capability as defaulting to false when
        // omitted, so an agent advertising only `{ "image": true }` must still
        // decode (a non-optional `audio` or `embeddedContext` would otherwise
        // fail the whole initialize result and silently drop image support).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            image = try c.decodeIfPresent(Bool.self, forKey: .image) ?? false
            audio = try c.decodeIfPresent(Bool.self, forKey: .audio) ?? false
            embeddedContext = try c.decodeIfPresent(Bool.self, forKey: .embeddedContext) ?? false
        }
    }
    public struct ACPAuthMethod: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let description: String?
        public let kind: Kind
        public let args: [String]?
        public let env: [String: String]?
        public let vars: [ACPAuthEnvVar]?
        public let meta: Meta?

        public var terminalAuth: TerminalAuthMeta? { meta?.terminalAuth }

        public init(
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

        public enum CodingKeys: String, CodingKey, Sendable {
            case id, name, description, args, env, vars
            case kind = "type"
            case meta = "_meta"
        }

        public init(from decoder: Decoder) throws {
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

        public func encode(to encoder: Encoder) throws {
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

        public enum Kind: Codable, Equatable, Sendable {
            case agent
            case terminal
            case envVar
            case unknown(String)

            public init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                switch try c.decode(String.self) {
                case "agent": self = .agent
                case "terminal": self = .terminal
                case "env_var": self = .envVar
                case let value: self = .unknown(value)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.singleValueContainer()
                switch self {
                case .agent: try c.encode("agent")
                case .terminal: try c.encode("terminal")
                case .envVar: try c.encode("env_var")
                case .unknown(let value): try c.encode(value)
                }
            }
        }

        public struct Meta: Codable, Equatable, Sendable {
            public let terminalAuth: TerminalAuthMeta?

            public enum CodingKeys: String, CodingKey, Sendable {
                case terminalAuth = "terminal-auth"
            }

            public init(terminalAuth: TerminalAuthMeta?) {
                self.terminalAuth = terminalAuth
            }
        }

        public struct TerminalAuthMeta: Codable, Equatable, Sendable {
            public let command: String?
            public let args: [String]?
            public let label: String?

            public init(command: String?, args: [String]?, label: String?) {
                self.command = command
                self.args = args
                self.label = label
            }
        }

        public struct ACPAuthEnvVar: Codable, Equatable, Sendable {
            public let name: String
            public let label: String?
            public let optional: Bool?
            public let secret: Bool?

            public init(name: String, label: String?, optional: Bool?, secret: Bool?) {
                self.name = name
                self.label = label
                self.optional = optional
                self.secret = secret
            }
        }
    }
}

/// Type-erased Codable used for `JSONRPCError.data` and `_meta` fields.
/// It only carries values that are JSON-compatible and safe to move across
/// actor boundaries as immutable payload data.
public struct AnyCodable: Codable, Equatable, Hashable, @unchecked Sendable {
    public let value: Any
    public init(_ value: Any) { self.value = value }

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

        public init(key: String, value: CanonicalValue) {
            self.key = key
            self.value = value
        }
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

    public init(from decoder: Decoder) throws {
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
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(canonicalValue)
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        lhs.canonicalValue == rhs.canonicalValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(canonicalValue)
    }
}

/// ACP `Implementation`: the name/version an agent reports in `initialize`.
public struct ACPImplementationInfo: Codable, Equatable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

// MARK: - session/new

/// Client-supplied `_meta` on session/new, session/load, session/resume, and
/// session/fork. Only the keys Alas sends are modelled.
public struct ACPSessionMeta: Codable, Equatable, Sendable {
    /// Read by `claude-agent-acp`, which merges `options` into the Claude
    /// Agent SDK options for the session's query process.
    public struct ClaudeCode: Codable, Equatable, Sendable {
        public struct Options: Codable, Equatable, Sendable {
            public let disallowedTools: [String]

            public init(disallowedTools: [String]) {
                self.disallowedTools = disallowedTools
            }
        }

        public let options: Options

        public init(options: Options) {
            self.options = options
        }
    }

    /// Read by `antigravity-acp`, which removes the named built-in tools
    /// from the session.
    public struct Agy: Codable, Equatable, Sendable {
        public let disabledTools: [String]

        public init(disabledTools: [String]) {
            self.disabledTools = disabledTools
        }
    }

    public var claudeCode: ClaudeCode? = nil
    public var agy: Agy? = nil

    public init(claudeCode: ClaudeCode? = nil, agy: Agy? = nil) {
        self.claudeCode = claudeCode
        self.agy = agy
    }
}

public struct ACPSessionNewParams: Codable, Equatable, Sendable {
    public let cwd: String
    public let mcpServers: [ACPMCPServer]
    public var meta: ACPSessionMeta? = nil

    public enum CodingKeys: String, CodingKey, Sendable {
        case cwd, mcpServers
        case meta = "_meta"
    }

    public init(cwd: String, mcpServers: [ACPMCPServer], meta: ACPSessionMeta? = nil) {
        self.cwd = cwd
        self.mcpServers = mcpServers
        self.meta = meta
    }
}

public struct ACPModelInfo: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }

    // ACP wire format uses `modelId` for the id; accept both shapes.
    public enum CodingKeys: String, CodingKey, Sendable { case id, modelId, name, description }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .modelId) {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .modelId)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

public struct ACPModeInfo: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let kind: ACPModeKind?

    public init(id: String, name: String, description: String? = nil, kind: ACPModeKind? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
    }
    public enum CodingKeys: String, CodingKey, Sendable { case id, modeId, name, description, meta = "_meta" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .modeId) {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
        let meta = (try? c.decodeIfPresent(ACPModeKindMetadata.self, forKey: .meta)) ?? nil
        kind = meta?.kind.flatMap(ACPModeKind.init(rawValue:))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

public struct ACPPromptSuggestion: Codable, Equatable, Hashable, Sendable {
    public let command: String
    public let description: String?
    public let hint: String?

    public init(command: String, description: String?, hint: String? = nil) {
        self.command = command
        self.description = description
        self.hint = hint
    }
}

public struct ACPSessionNewResult: Codable, Equatable, Sendable {
    public let sessionId: String
    public let availableModels: [ACPModelInfo]
    public let availableModes: [ACPModeInfo]
    public let currentModel: String?
    public let currentMode: String?
    public let promptSuggestions: [ACPPromptSuggestion]
    public let configOptions: [ACPConfigOption]

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId, availableModels, availableModes, currentModel, currentMode, promptSuggestions, configOptions
        case models, modes
    }

    // We only ever receive this type — encoding is not used in production.
    // Provide a flat encode against the CodingKeys we read into so the
    // synthesized Codable contract holds.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(availableModels, forKey: .availableModels)
        try c.encode(availableModes, forKey: .availableModes)
        try c.encodeIfPresent(currentModel, forKey: .currentModel)
        try c.encodeIfPresent(currentMode, forKey: .currentMode)
        try c.encode(promptSuggestions, forKey: .promptSuggestions)
        try c.encode(configOptions, forKey: .configOptions)
    }

    public init(
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

    public init(from decoder: Decoder) throws {
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

    /// Only an id: no models, modes, or config options came with it.
    public var isBareSessionID: Bool {
        availableModels.isEmpty && availableModes.isEmpty && configOptions.isEmpty
    }

    public func withSessionId(_ sessionId: String) -> ACPSessionNewResult {
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

public struct ACPSessionLoadParams: Codable, Equatable, Sendable {
    public let cwd: String
    public let sessionId: String
    public let mcpServers: [ACPMCPServer]
    public var meta: ACPSessionMeta? = nil

    public enum CodingKeys: String, CodingKey, Sendable {
        case cwd, sessionId, mcpServers
        case meta = "_meta"
    }

    public init(cwd: String, sessionId: String, mcpServers: [ACPMCPServer], meta: ACPSessionMeta? = nil) {
        self.cwd = cwd
        self.sessionId = sessionId
        self.mcpServers = mcpServers
        self.meta = meta
    }
}

// MARK: - session/list + session/resume + session/fork

public struct ACPSessionListParams: Codable, Equatable, Sendable {
    public let cwd: String?
    public let cursor: String?

    public init(cwd: String?, cursor: String?) {
        self.cwd = cwd
        self.cursor = cursor
    }
}

public struct ACPSessionListResult: Codable, Equatable, Sendable {
    public let sessions: [ACPAgentSessionInfo]
    public let nextCursor: String?

    public init(sessions: [ACPAgentSessionInfo], nextCursor: String? = nil) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

public struct ACPAgentSessionInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionId }

    public let sessionId: String
    public let cwd: String
    public let title: String?
    public let updatedAt: String?
    public let additionalDirectories: [String]?

    public init(
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

public typealias ACPSessionResumeParams = ACPSessionLoadParams
public typealias ACPSessionForkParams = ACPSessionLoadParams

// MARK: - session/close

public struct ACPSessionCloseParams: Codable, Equatable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// MARK: - session/delete

public struct ACPSessionDeleteParams: Codable, Equatable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// MARK: - session/cancel

public struct ACPSessionCancelParams: Codable, Equatable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

// MARK: - $/cancel_request (inbound notification)

/// OpenCode v2 sends this to cancel a pending `session/request_permission`
/// (or `fs/write_text_file`) when the turn itself is cancelled.
public struct ACPCancelRequestParams: Codable, Equatable, Sendable {
    public let id: JSONRPCID

    public init(id: JSONRPCID) {
        self.id = id
    }
}

// MARK: - session/setMode + setModel

public struct ACPSessionSetModeParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let modeId: String

    public init(sessionId: String, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }
}

public struct ACPSessionSetModelParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let modelId: String

    public init(sessionId: String, modelId: String) {
        self.sessionId = sessionId
        self.modelId = modelId
    }
}

// MARK: - providers

public struct ACPProvidersListParams: Codable, Equatable, Sendable {
    public init() {
    }}

public struct ACPProviderCurrentConfig: Codable, Equatable, Hashable, Sendable {
    public let apiType: String
    public let baseUrl: String

    public init(apiType: String, baseUrl: String) {
        self.apiType = apiType
        self.baseUrl = baseUrl
    }
}

public struct ACPProviderInfo: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { providerId }

    public let providerId: String
    public let name: String?
    public let supported: [String]
    public let required: Bool
    public let current: ACPProviderCurrentConfig?

    public init(
        providerId: String,
        name: String? = nil,
        supported: [String],
        required: Bool,
        current: ACPProviderCurrentConfig?
    ) {
        self.providerId = providerId
        self.name = name
        self.supported = supported
        self.required = required
        self.current = current
    }
}

public struct ACPProvidersListResult: Codable, Equatable, Sendable {
    public let providers: [ACPProviderInfo]

    public init(providers: [ACPProviderInfo]) {
        self.providers = providers
    }
}

public struct ACPProviderSetParams: Codable, Equatable, Sendable {
    public let providerId: String
    public let apiType: String
    public let baseUrl: String
    public let headers: [String: String]?

    public init(
        providerId: String,
        apiType: String,
        baseUrl: String,
        headers: [String: String]? = nil
    ) {
        self.providerId = providerId
        self.apiType = apiType
        self.baseUrl = baseUrl
        self.headers = headers
    }
}

public struct ACPProviderDisableParams: Codable, Equatable, Sendable {
    public let providerId: String

    public init(providerId: String) {
        self.providerId = providerId
    }
}

// MARK: - session/prompt

public struct ACPSessionPromptParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let prompt: [ACPContentBlock]

    public init(sessionId: String, prompt: [ACPContentBlock]) {
        self.sessionId = sessionId
        self.prompt = prompt
    }
}

public enum ACPContentBlock: Codable, Equatable, Sendable {
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

        public init(uri: String, mimeType: String?, text: String?, blob: String?) {
            self.uri = uri
            self.mimeType = mimeType
            self.text = text
            self.blob = blob
        }
    }

    public init(from decoder: Decoder) throws {
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
    public func encode(to encoder: Encoder) throws {
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
public enum ACPToolCallContent: Codable, Equatable, Sendable {
    case content(ACPContentBlock)
    /// `kind`/`diffStats` come from the AIR diff-statistics extension
    /// (`_meta.kind` and `_meta.jetbrains.air.diffStats`) — claude-agent-acp
    /// ≥ 0.78 (#1122) and codex-acp ≥ 1.12 (#501). `diffStats` is nil when
    /// the adapter can't produce valid counts; callers fall back to
    /// computing their own.
    case diff(path: String, oldText: String?, newText: String, kind: String?, diffStats: ACPDiffStats?)
    case terminal(terminalId: String)
    /// Forward-compatibility bucket so a future spec variant doesn't get
    /// misdecoded as empty text (the previous bug pattern).
    case unknown

    private enum Keys: String, CodingKey {
        case type, content, path, oldText, newText, terminalId
        case meta = "_meta"
    }

    /// Wire shape of `_meta` on a `diff` content block. See
    /// https://github.com/agentclientprotocol/codex-acp/blob/main/docs/diff-statistics-extension.md.
    private struct DiffMeta: Codable {
        let kind: String?
        let jetbrains: Jetbrains?
        struct Jetbrains: Codable { let air: Air? }
        struct Air: Codable { let diffStats: ACPDiffStats? }

        public init(kind: String?, jetbrains: Jetbrains?) {
            self.kind = kind
            self.jetbrains = jetbrains
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "content":
            self = .content(try c.decode(ACPContentBlock.self, forKey: .content))
        case "diff":
            let meta = (try? c.decodeIfPresent(DiffMeta.self, forKey: .meta)) ?? nil
            self = .diff(
                path: try c.decode(String.self, forKey: .path),
                oldText: try? c.decode(String.self, forKey: .oldText),
                newText: try c.decode(String.self, forKey: .newText),
                kind: meta?.kind,
                diffStats: meta?.jetbrains?.air?.diffStats)
        case "terminal":
            self = .terminal(terminalId: try c.decode(String.self, forKey: .terminalId))
        case "text", "resource_link", "image", "resource":
            // Some adapters (and real permission-request payloads) send a
            // bare ACPContentBlock here instead of wrapping it in the
            // spec's tagged union. Decode it directly rather than losing it
            // to `.unknown` — that silently drops the block's text.
            self = .content(try ACPContentBlock(from: decoder))
        default:
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .content(let b):
            try c.encode("content", forKey: .type)
            try c.encode(b, forKey: .content)
        case .diff(let path, let old, let new, let kind, let diffStats):
            try c.encode("diff", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(old, forKey: .oldText)
            try c.encode(new, forKey: .newText)
            if kind != nil || diffStats != nil {
                let meta = DiffMeta(
                    kind: kind,
                    jetbrains: diffStats.map { DiffMeta.Jetbrains(air: DiffMeta.Air(diffStats: $0)) })
                try c.encode(meta, forKey: .meta)
            }
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

/// AIR "diff statistics" extension payload — `_meta.jetbrains.air.diffStats`
/// on a `diff` content block. All fields are required by the spec when
/// present at all; a payload missing either count fails to decode and the
/// whole `_meta` is dropped (the caller falls back to computing its own).
public struct ACPDiffStats: Codable, Equatable, Hashable, Sendable {
    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}
