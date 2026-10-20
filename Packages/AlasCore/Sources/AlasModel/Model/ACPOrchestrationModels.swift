import Foundation

public struct ACPOrchestrationSessionOrigin: Equatable, Sendable {
    public let sessionId: String
    public let projectId: String
    public let worktreeId: String

    public init(sessionId: String, projectId: String, worktreeId: String) {
        self.sessionId = sessionId
        self.projectId = projectId
        self.worktreeId = worktreeId
    }
}

public enum ACPDelegatedSessionWorktreeTarget: Equatable, Sendable {
    case current
    case existing(worktreeId: String)
    case new(branch: String, base: String?)
}

/// A parent's explicit model/reasoning choice for a delegated child. Both
/// ids are the child agent's own, never translated between providers. It is
/// applied, and acknowledged by the agent, before the child's first prompt;
/// a choice the agent cannot honor fails the child instead of falling back.
public struct ACPDelegatedModelSelection: Equatable, Sendable {
    public let model: String?
    public let reasoning: String?

    /// Nil when neither value is set, so "omitted" has one representation.
    public init?(model: String?, reasoning: String?) {
        guard model != nil || reasoning != nil else { return nil }
        self.model = model
        self.reasoning = reasoning
    }
}

public struct ACPDelegatedSessionNewRequest: Equatable, Sendable {
    public let prompt: String
    public let agentId: String?
    public let worktree: ACPDelegatedSessionWorktreeTarget
    public var modelSelection: ACPDelegatedModelSelection? = nil
    public var role: String? = nil

    public init(prompt: String, agentId: String?, worktree: ACPDelegatedSessionWorktreeTarget, modelSelection: ACPDelegatedModelSelection? = nil, role: String? = nil) {
        self.prompt = prompt
        self.agentId = agentId
        self.worktree = worktree
        self.modelSelection = modelSelection
        self.role = role
    }
}

public struct ACPDelegatedSessionMessageRequest: Equatable, Sendable {
    public let targetSessionId: String
    public let prompt: String

    public init(targetSessionId: String, prompt: String) {
        self.targetSessionId = targetSessionId
        self.prompt = prompt
    }
}

public enum ACPDelegatedWorktreeRequest: Codable, Equatable, Sendable {
    case current(worktreeId: String)
    case existing(worktreeId: String)
    case new(branch: String, base: String?, destinationPath: String, optimisticId: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case worktreeId
        case branch
        case base
        case destinationPath
        case optimisticId
    }

    private enum Kind: String, Codable {
        case current
        case existing
        case new
    }

    public var worktreeId: String? {
        switch self {
        case .current(let id), .existing(let id): id
        case .new(_, _, _, let id): id
        }
    }

    public var destinationPath: String? {
        guard case .new(_, _, let path, _) = self else { return nil }
        return path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .current:
            self = .current(worktreeId: try container.decode(String.self, forKey: .worktreeId))
        case .existing:
            self = .existing(worktreeId: try container.decode(String.self, forKey: .worktreeId))
        case .new:
            self = .new(
                branch: try container.decode(String.self, forKey: .branch),
                base: try container.decodeIfPresent(String.self, forKey: .base),
                destinationPath: try container.decode(String.self, forKey: .destinationPath),
                optimisticId: try container.decode(String.self, forKey: .optimisticId)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .current(let worktreeId):
            try container.encode(Kind.current, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .existing(let worktreeId):
            try container.encode(Kind.existing, forKey: .kind)
            try container.encode(worktreeId, forKey: .worktreeId)
        case .new(let branch, let base, let destinationPath, let optimisticId):
            try container.encode(Kind.new, forKey: .kind)
            try container.encode(branch, forKey: .branch)
            try container.encodeIfPresent(base, forKey: .base)
            try container.encode(destinationPath, forKey: .destinationPath)
            try container.encode(optimisticId, forKey: .optimisticId)
        }
    }
}

public enum ACPDelegationPhase: String, Codable, Equatable, Sendable {
    case creatingWorktree
    case starting
    case ready
    case failed
    case closed
}

public struct ACPDelegationRecord: Equatable, Sendable {
    public let childSessionId: String
    public let parentSessionId: String
    public let projectId: String
    public let parentWorktreeId: String
    public var childWorktreeId: String?
    public let agentId: String
    public let worktreeRequest: ACPDelegatedWorktreeRequest
    public var pendingInitialPrompt: String?
    public var phase: ACPDelegationPhase
    public var failureMessage: String?
    public let createdAt: Int64
    public var updatedAt: Int64
    /// Epoch **milliseconds** (not `createdAt`/`updatedAt`'s seconds) of the
    /// most recent `session_send` this child addressed to its parent. Used
    /// to decide whether a finished turn already reported; compared against
    /// `ACPTurnCompletion.startedAt`, which is also milliseconds — whole
    /// seconds are too coarse to distinguish a report from the tail of one
    /// turn from the start of the next.
    public var lastParentReportAt: Int64? = nil
    /// Persisted so a delayed start (new worktree) and startup recovery apply
    /// the same selection before the pending initial prompt.
    public var modelSelection: ACPDelegatedModelSelection? = nil
    public var role: String? = nil

    public init(childSessionId: String, parentSessionId: String, projectId: String, parentWorktreeId: String, childWorktreeId: String? = nil, agentId: String, worktreeRequest: ACPDelegatedWorktreeRequest, pendingInitialPrompt: String? = nil, phase: ACPDelegationPhase, failureMessage: String? = nil, createdAt: Int64, updatedAt: Int64, lastParentReportAt: Int64? = nil, modelSelection: ACPDelegatedModelSelection? = nil, role: String? = nil) {
        self.childSessionId = childSessionId
        self.parentSessionId = parentSessionId
        self.projectId = projectId
        self.parentWorktreeId = parentWorktreeId
        self.childWorktreeId = childWorktreeId
        self.agentId = agentId
        self.worktreeRequest = worktreeRequest
        self.pendingInitialPrompt = pendingInitialPrompt
        self.phase = phase
        self.failureMessage = failureMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastParentReportAt = lastParentReportAt
        self.modelSelection = modelSelection
        self.role = role
    }
}

/// How the inbox delivers a delegated message to its target session.
public enum ACPDelegatedMessageKind: String, Codable, Equatable, Sendable {
    /// Queued as a prompt; the target runs a turn.
    case prompt
    /// Appended to the target transcript as a system notice; no turn.
    case notice
}

public struct ACPDelegatedMessage: Equatable, Sendable {
    public let id: String
    public let sourceSessionId: String
    public let targetSessionId: String
    public let prompt: String
    public let createdAt: Int64
    public var kind: ACPDelegatedMessageKind = .prompt

    public init(id: String, sourceSessionId: String, targetSessionId: String, prompt: String, createdAt: Int64, kind: ACPDelegatedMessageKind = .prompt) {
        self.id = id
        self.sourceSessionId = sourceSessionId
        self.targetSessionId = targetSessionId
        self.prompt = prompt
        self.createdAt = createdAt
        self.kind = kind
    }
}

public struct ACPDelegatedMessageClaim: Equatable, Sendable {
    public let instanceId: String
    public let token: String
    public let expiresAt: Int64

    public init(instanceId: String, token: String, expiresAt: Int64) {
        self.instanceId = instanceId
        self.token = token
        self.expiresAt = expiresAt
    }
}

public struct ACPClaimedDelegatedMessage: Equatable, Sendable {
    public let message: ACPDelegatedMessage
    public let claim: ACPDelegatedMessageClaim

    public init(message: ACPDelegatedMessage, claim: ACPDelegatedMessageClaim) {
        self.message = message
        self.claim = claim
    }
}

public struct ACPOrchestrationSessionSummary: Codable, Equatable, Sendable {
    public let sessionId: String
    public let relationship: String?
    public let agentId: String
    public let worktreeId: String
    public let state: String
    public let failure: String?
    public let createdAt: Int64
    public var role: String? = nil

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId = "session_id"
        case relationship, role
        case agentId = "agent_id"
        case worktreeId = "worktree_id"
        case state
        case failure
        case createdAt = "created_at"
    }

    public init(sessionId: String, relationship: String?, agentId: String, worktreeId: String, state: String, failure: String?, createdAt: Int64, role: String? = nil) {
        self.sessionId = sessionId
        self.relationship = relationship
        self.agentId = agentId
        self.worktreeId = worktreeId
        self.state = state
        self.failure = failure
        self.createdAt = createdAt
        self.role = role
    }
}

public struct ACPOrchestrationListResponse: Codable, Equatable, Sendable {
    public let sessions: [ACPOrchestrationSessionSummary]

    public init(sessions: [ACPOrchestrationSessionSummary]) {
        self.sessions = sessions
    }
}

public struct ACPOrchestrationNewResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    public let state: String
    public let worktreeId: String?

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId = "session_id"
        case state
        case worktreeId = "worktree_id"
    }

    public init(sessionId: String, state: String, worktreeId: String?) {
        self.sessionId = sessionId
        self.state = state
        self.worktreeId = worktreeId
    }
}

/// Wire schema for `agent_list` (MCP) and `alas agent list` (CLI). Bump
/// `currentVersion` on any breaking change to these fields.
public struct ACPDelegationAgentListResponse: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    /// The agent `session_new` uses when `agent` is omitted, when known.
    public let callerAgentId: String?
    /// False for a delegated child, which cannot create sessions of its own.
    public let canDelegate: Bool
    /// The worktree whose install state `available` reflects.
    public let worktreeId: String
    public let agents: [ACPDelegationAgentSummary]

    public enum CodingKeys: String, CodingKey, Sendable {
        case version
        case callerAgentId = "caller_agent_id"
        case canDelegate = "can_delegate"
        case worktreeId = "worktree_id"
        case agents
    }

    public init(version: Int, callerAgentId: String?, canDelegate: Bool, worktreeId: String, agents: [ACPDelegationAgentSummary]) {
        self.version = version
        self.callerAgentId = callerAgentId
        self.canDelegate = canDelegate
        self.worktreeId = worktreeId
        self.agents = agents
    }
}

public struct ACPDelegationAgentSummary: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// True only when `availability` is `.available`: the one state
    /// `session_new` accepts for this caller's worktree.
    public let available: Bool
    public let availability: ACPDelegationAgentAvailability
    public let modelSelection: ACPDelegationModelSelection
    public let modelCatalog: ACPDelegationModelCatalog

    public enum CodingKeys: String, CodingKey, Sendable {
        case id
        case displayName = "display_name"
        case available
        case availability
        case modelSelection = "model_selection"
        case modelCatalog = "model_catalog"
    }

    public init(id: String, displayName: String, available: Bool, availability: ACPDelegationAgentAvailability, modelSelection: ACPDelegationModelSelection, modelCatalog: ACPDelegationModelCatalog) {
        self.id = id
        self.displayName = displayName
        self.available = available
        self.availability = availability
        self.modelSelection = modelSelection
        self.modelCatalog = modelCatalog
    }
}

public enum ACPDelegationAgentAvailability: String, Codable, Equatable, Sendable {
    case available
    /// Turned off in Settings.
    case disabled
    /// Enabled, but its CLI was not detected where the caller's worktree runs.
    case notInstalled = "not_installed"
    /// A remote host's install probe has not produced an answer.
    case unknown
}

public enum ACPDelegationModelSelection: String, Codable, Equatable, Sendable {
    /// The agent has advertised a model list.
    case supported
    /// A live session of this agent advertised no models during this app run.
    case unsupported
    /// No live session of this agent has reported models yet.
    case unknown
}

public struct ACPDelegationModelCatalog: Codable, Equatable, Sendable {
    public let state: ACPDelegationModelCatalogState
    /// Non-empty only for `.known` and `.stale`. Ids are the agent's own
    /// model ids; the agent stays the authority when a session starts.
    public let models: [ACPAgentModel]

    public init(state: ACPDelegationModelCatalogState, models: [ACPAgentModel]) {
        self.state = state
        self.models = models
    }
}

public enum ACPDelegationModelCatalogState: String, Codable, Equatable, Sendable {
    /// Advertised by a live session of this agent during this app run.
    case known
    /// Remembered from an earlier app run, or not re-confirmed since.
    case stale
    /// Nothing remembered and no live session has reported yet.
    case notLoaded = "not_loaded"
    /// A live session reported no model list and none is remembered.
    case unsupported
    /// The agent is not a valid delegation target for this caller.
    case unavailable
}

public struct ACPOrchestrationSendResponse: Codable, Equatable, Sendable {
    public let messageId: String
    public let state: String

    public enum CodingKeys: String, CodingKey, Sendable {
        case messageId = "message_id"
        case state
    }

    public init(messageId: String, state: String) {
        self.messageId = messageId
        self.state = state
    }
}

/// The session tools that look at or stop another session's turns, routed
/// through one entry point (`ACPSessionOrchestrationCoordinator.perform`).
public enum ACPDelegatedSessionAction: Equatable, Sendable {
    case read(ACPDelegatedSessionReadRequest)
    case search(ACPDelegatedSessionSearchRequest)
    case wait(ACPDelegatedSessionWaitRequest)
    case interrupt(targetSessionId: String)
}

public struct ACPDelegatedSessionReadRequest: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maxLimit = 100
    public static let defaultMaxChars = 8_000
    public static let maxMaxChars = 100_000

    public let targetSessionId: String
    /// First entry to return; nil reads the latest entries.
    public var offset: Int? = nil
    public var limit: Int = defaultLimit
    public var maxChars: Int = defaultMaxChars

    public init(targetSessionId: String, offset: Int? = nil, limit: Int = defaultLimit, maxChars: Int = defaultMaxChars) {
        self.targetSessionId = targetSessionId
        self.offset = offset
        self.limit = limit
        self.maxChars = maxChars
    }
}

public struct ACPDelegatedSessionSearchRequest: Equatable, Sendable {
    public static let defaultLimit = 20
    public static let maxLimit = 100

    public let query: String
    public var limit: Int = defaultLimit

    public init(query: String, limit: Int = defaultLimit) {
        self.query = query
        self.limit = limit
    }
}

public struct ACPDelegatedSessionWaitRequest: Equatable, Sendable {
    /// Below the CLI client's 30-second socket read timeout.
    public static let maxTimeoutMillis = 20_000
    public static let maxSessions = 20

    public let targetSessionIds: [String]
    public var timeoutMillis: Int = maxTimeoutMillis

    public init(targetSessionIds: [String], timeoutMillis: Int = maxTimeoutMillis) {
        self.targetSessionIds = targetSessionIds
        self.timeoutMillis = timeoutMillis
    }
}

/// `session_read`: one page of a session's text-only transcript.
public struct ACPOrchestrationReadResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    public let entries: [ACPTranscriptEntry]
    public let start: Int
    /// Pass as `offset` to read on from the last returned entry.
    public let end: Int
    public let total: Int

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId = "session_id"
        case entries
        case start
        case end
        case total
    }

    public init(sessionId: String, entries: [ACPTranscriptEntry], start: Int, end: Int, total: Int) {
        self.sessionId = sessionId
        self.entries = entries
        self.start = start
        self.end = end
        self.total = total
    }
}

public struct ACPOrchestrationSearchResponse: Codable, Equatable, Sendable {
    public struct Match: Codable, Equatable, Sendable {
        public let sessionId: String
        public let index: Int
        public let role: String
        public let snippet: String

        public enum CodingKeys: String, CodingKey, Sendable {
            case sessionId = "session_id"
            case index
            case role
            case snippet
        }

        public init(sessionId: String, index: Int, role: String, snippet: String) {
            self.sessionId = sessionId
            self.index = index
            self.role = role
            self.snippet = snippet
        }
    }

    public let matches: [Match]
    /// True when more matches existed than `limit` allowed.
    public let truncated: Bool

    public init(matches: [Match], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}

public struct ACPOrchestrationWaitResponse: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public let sessionId: String
        public let state: String
        /// False while the session still has a turn running or queued.
        public let settled: Bool
        public let lastAgentText: String?
        public let failure: String?

        public enum CodingKeys: String, CodingKey, Sendable {
            case sessionId = "session_id"
            case state
            case settled
            case lastAgentText = "last_agent_text"
            case failure
        }

        public init(sessionId: String, state: String, settled: Bool, lastAgentText: String?, failure: String?) {
            self.sessionId = sessionId
            self.state = state
            self.settled = settled
            self.lastAgentText = lastAgentText
            self.failure = failure
        }
    }

    public let sessions: [Session]
    public let timedOut: Bool

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessions
        case timedOut = "timed_out"
    }

    public init(sessions: [Session], timedOut: Bool) {
        self.sessions = sessions
        self.timedOut = timedOut
    }
}

public struct ACPOrchestrationInterruptResponse: Codable, Equatable, Sendable {
    public let sessionId: String
    /// False when the session had no turn to cancel, or another Alas
    /// instance drives it. The child's turn outcome still arrives the usual
    /// way once the agent stops.
    public let cancelRequested: Bool

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId = "session_id"
        case cancelRequested = "cancel_requested"
    }

    public init(sessionId: String, cancelRequested: Bool) {
        self.sessionId = sessionId
        self.cancelRequested = cancelRequested
    }
}
