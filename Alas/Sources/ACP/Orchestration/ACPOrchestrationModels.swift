import Foundation

struct ACPOrchestrationSessionOrigin: Equatable, Sendable {
    let sessionId: String
    let projectId: String
    let worktreeId: String
}

enum ACPDelegatedSessionWorktreeTarget: Equatable, Sendable {
    case current
    case existing(worktreeId: String)
    case new(branch: String, base: String?)
}

/// A parent's explicit model/reasoning choice for a delegated child. Both
/// ids are the child agent's own, never translated between providers. It is
/// applied, and acknowledged by the agent, before the child's first prompt;
/// a choice the agent cannot honor fails the child instead of falling back.
struct ACPDelegatedModelSelection: Equatable, Sendable {
    let model: String?
    let reasoning: String?

    /// Nil when neither value is set, so "omitted" has one representation.
    init?(model: String?, reasoning: String?) {
        guard model != nil || reasoning != nil else { return nil }
        self.model = model
        self.reasoning = reasoning
    }
}

struct ACPDelegatedSessionNewRequest: Equatable, Sendable {
    let prompt: String
    let agentId: String?
    let worktree: ACPDelegatedSessionWorktreeTarget
    var modelSelection: ACPDelegatedModelSelection? = nil
    var role: String? = nil
}

struct ACPDelegatedSessionMessageRequest: Equatable, Sendable {
    let targetSessionId: String
    let prompt: String
}

enum ACPDelegatedWorktreeRequest: Codable, Equatable, Sendable {
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

    var worktreeId: String? {
        switch self {
        case .current(let id), .existing(let id): id
        case .new(_, _, _, let id): id
        }
    }

    var destinationPath: String? {
        guard case .new(_, _, let path, _) = self else { return nil }
        return path
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

enum ACPDelegationPhase: String, Codable, Equatable, Sendable {
    case creatingWorktree
    case starting
    case ready
    case failed
    case closed
}

struct ACPDelegationRecord: Equatable, Sendable {
    let childSessionId: String
    let parentSessionId: String
    let projectId: String
    let parentWorktreeId: String
    var childWorktreeId: String?
    let agentId: String
    let worktreeRequest: ACPDelegatedWorktreeRequest
    var pendingInitialPrompt: String?
    var phase: ACPDelegationPhase
    var failureMessage: String?
    let createdAt: Int64
    var updatedAt: Int64
    /// Epoch **milliseconds** (not `createdAt`/`updatedAt`'s seconds) of the
    /// most recent `session_send` this child addressed to its parent. Used
    /// to decide whether a finished turn already reported; compared against
    /// `ACPTurnCompletion.startedAt`, which is also milliseconds — whole
    /// seconds are too coarse to distinguish a report from the tail of one
    /// turn from the start of the next.
    var lastParentReportAt: Int64? = nil
    /// Persisted so a delayed start (new worktree) and startup recovery apply
    /// the same selection before the pending initial prompt.
    var modelSelection: ACPDelegatedModelSelection? = nil
    var role: String? = nil
}

/// How the inbox delivers a delegated message to its target session.
enum ACPDelegatedMessageKind: String, Codable, Equatable, Sendable {
    /// Queued as a prompt; the target runs a turn.
    case prompt
    /// Appended to the target transcript as a system notice; no turn.
    case notice
}

struct ACPDelegatedMessage: Equatable, Sendable {
    let id: String
    let sourceSessionId: String
    let targetSessionId: String
    let prompt: String
    let createdAt: Int64
    var kind: ACPDelegatedMessageKind = .prompt
}

struct ACPDelegatedMessageClaim: Equatable, Sendable {
    let instanceId: String
    let token: String
    let expiresAt: Int64
}

struct ACPClaimedDelegatedMessage: Equatable, Sendable {
    let message: ACPDelegatedMessage
    let claim: ACPDelegatedMessageClaim
}

struct ACPOrchestrationSessionSummary: Codable, Equatable, Sendable {
    let sessionId: String
    let relationship: String?
    let agentId: String
    let worktreeId: String
    let state: String
    let failure: String?
    let createdAt: Int64
    var role: String? = nil

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case relationship, role
        case agentId = "agent_id"
        case worktreeId = "worktree_id"
        case state
        case failure
        case createdAt = "created_at"
    }
}

struct ACPOrchestrationListResponse: Codable, Equatable, Sendable {
    let sessions: [ACPOrchestrationSessionSummary]
}

struct ACPOrchestrationNewResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let state: String
    let worktreeId: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case state
        case worktreeId = "worktree_id"
    }
}

/// Wire schema for `agent_list` (MCP) and `alas agent list` (CLI). Bump
/// `currentVersion` on any breaking change to these fields.
struct ACPDelegationAgentListResponse: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    /// The agent `session_new` uses when `agent` is omitted, when known.
    let callerAgentId: String?
    /// False for a delegated child, which cannot create sessions of its own.
    let canDelegate: Bool
    /// The worktree whose install state `available` reflects.
    let worktreeId: String
    let agents: [ACPDelegationAgentSummary]

    enum CodingKeys: String, CodingKey {
        case version
        case callerAgentId = "caller_agent_id"
        case canDelegate = "can_delegate"
        case worktreeId = "worktree_id"
        case agents
    }
}

struct ACPDelegationAgentSummary: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    /// True only when `availability` is `.available`: the one state
    /// `session_new` accepts for this caller's worktree.
    let available: Bool
    let availability: ACPDelegationAgentAvailability
    let modelSelection: ACPDelegationModelSelection
    let modelCatalog: ACPDelegationModelCatalog

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case available
        case availability
        case modelSelection = "model_selection"
        case modelCatalog = "model_catalog"
    }
}

enum ACPDelegationAgentAvailability: String, Codable, Equatable, Sendable {
    case available
    /// Turned off in Settings.
    case disabled
    /// Enabled, but its CLI was not detected where the caller's worktree runs.
    case notInstalled = "not_installed"
    /// A remote host's install probe has not produced an answer.
    case unknown
}

enum ACPDelegationModelSelection: String, Codable, Equatable, Sendable {
    /// The agent has advertised a model list.
    case supported
    /// A live session of this agent advertised no models during this app run.
    case unsupported
    /// No live session of this agent has reported models yet.
    case unknown
}

struct ACPDelegationModelCatalog: Codable, Equatable, Sendable {
    let state: ACPDelegationModelCatalogState
    /// Non-empty only for `.known` and `.stale`. Ids are the agent's own
    /// model ids; the agent stays the authority when a session starts.
    let models: [ACPAgentModelCatalog.Model]
}

enum ACPDelegationModelCatalogState: String, Codable, Equatable, Sendable {
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

struct ACPOrchestrationSendResponse: Codable, Equatable, Sendable {
    let messageId: String
    let state: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case state
    }
}

/// The session tools that look at or stop another session's turns, routed
/// through one entry point (`ACPSessionOrchestrationCoordinator.perform`).
enum ACPDelegatedSessionAction: Equatable, Sendable {
    case read(ACPDelegatedSessionReadRequest)
    case search(ACPDelegatedSessionSearchRequest)
    case wait(ACPDelegatedSessionWaitRequest)
    case interrupt(targetSessionId: String)
}

struct ACPDelegatedSessionReadRequest: Equatable, Sendable {
    static let defaultLimit = 20
    static let maxLimit = 100
    static let defaultMaxChars = 8_000
    static let maxMaxChars = 100_000

    let targetSessionId: String
    /// First entry to return; nil reads the latest entries.
    var offset: Int? = nil
    var limit: Int = defaultLimit
    var maxChars: Int = defaultMaxChars
}

struct ACPDelegatedSessionSearchRequest: Equatable, Sendable {
    static let defaultLimit = 20
    static let maxLimit = 100

    let query: String
    var limit: Int = defaultLimit
}

struct ACPDelegatedSessionWaitRequest: Equatable, Sendable {
    /// Below the CLI client's 30-second socket read timeout.
    static let maxTimeoutMillis = 20_000
    static let maxSessions = 20

    let targetSessionIds: [String]
    var timeoutMillis: Int = maxTimeoutMillis
}

/// `session_read`: one page of a session's text-only transcript.
struct ACPOrchestrationReadResponse: Codable, Equatable, Sendable {
    let sessionId: String
    let entries: [ACPSessionTranscriptReader.Entry]
    let start: Int
    /// Pass as `offset` to read on from the last returned entry.
    let end: Int
    let total: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case entries
        case start
        case end
        case total
    }
}

struct ACPOrchestrationSearchResponse: Codable, Equatable, Sendable {
    struct Match: Codable, Equatable, Sendable {
        let sessionId: String
        let index: Int
        let role: String
        let snippet: String

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case index
            case role
            case snippet
        }
    }

    let matches: [Match]
    /// True when more matches existed than `limit` allowed.
    let truncated: Bool
}

struct ACPOrchestrationWaitResponse: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        let sessionId: String
        let state: String
        /// False while the session still has a turn running or queued.
        let settled: Bool
        let lastAgentText: String?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case state
            case settled
            case lastAgentText = "last_agent_text"
            case failure
        }
    }

    let sessions: [Session]
    let timedOut: Bool

    enum CodingKeys: String, CodingKey {
        case sessions
        case timedOut = "timed_out"
    }
}

struct ACPOrchestrationInterruptResponse: Codable, Equatable, Sendable {
    let sessionId: String
    /// False when the session had no turn to cancel, or another Alas
    /// instance drives it. The child's turn outcome still arrives the usual
    /// way once the agent stops.
    let cancelRequested: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cancelRequested = "cancel_requested"
    }
}
