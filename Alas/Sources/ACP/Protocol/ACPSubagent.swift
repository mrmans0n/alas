import Foundation

/// Native subagent (child session) support, as drafted in ACP RFD 1992 and
/// already shipped by claude-agent-acp >= 0.71 and codex-acp >= 1.7.
///
/// The agent announces a child with `subagent_spawned` on the PARENT session,
/// then streams the child's own output as ordinary `session/update`
/// notifications whose `sessionId` is the child's. Permission and elicitation
/// requests for a child keep routing through the root session, so nothing
/// about the prompt queue changes.

/// `{"sessionUpdate": "subagent_spawned", ...}` on the parent session.
struct ACPSubagentSpawn: Codable, Equatable, Sendable {
    let subagentSessionId: String
    let name: String?
    let task: String?
    let capabilities: ACPSubagentCapabilities

    init(
        subagentSessionId: String,
        name: String? = nil,
        task: String? = nil,
        capabilities: ACPSubagentCapabilities = .init()
    ) {
        self.subagentSessionId = subagentSessionId
        self.name = name
        self.task = task
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case subagentSessionId, name, task, capabilities
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subagentSessionId = try c.decode(String.self, forKey: .subagentSessionId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        task = try? c.decodeIfPresent(String.self, forKey: .task)
        capabilities = (try? c.decodeIfPresent(ACPSubagentCapabilities.self, forKey: .capabilities))
            ?? .init()
    }
}

/// Per-child operations the agent says it will honour. Absent members mean
/// "not supported" — the row must not offer an action the agent will reject.
struct ACPSubagentCapabilities: Codable, Equatable, Sendable {
    let cancel: EmptyObject?
    let close: EmptyObject?

    init(cancel: EmptyObject? = nil, close: EmptyObject? = nil) {
        self.cancel = cancel
        self.close = close
    }

    static let cancellable = ACPSubagentCapabilities(cancel: .init())

    var supportsCancel: Bool { cancel != nil }
    var supportsClose: Bool { close != nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cancel = try? c.decodeIfPresent(EmptyObject.self, forKey: .cancel)
        close = try? c.decodeIfPresent(EmptyObject.self, forKey: .close)
    }
}

/// `{"sessionUpdate": "subagent_state_update", ...}` on the parent session.
struct ACPSubagentStateUpdate: Codable, Equatable, Sendable {
    let subagentSessionId: String
    let state: ACPSubagentState
    /// Diagnostic text for a failure. The standard ACP `subagent_state_update`
    /// has no such field, so this is nil for it; OpenCode's own status
    /// notification carries one and is normalized onto this field so the
    /// failure reason is not lost once folded into the standard shape.
    let error: String?

    init(subagentSessionId: String, state: ACPSubagentState, error: String? = nil) {
        self.subagentSessionId = subagentSessionId
        self.state = state
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case subagentSessionId, state, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subagentSessionId = try c.decode(String.self, forKey: .subagentSessionId)
        state = try c.decode(ACPSubagentState.self, forKey: .state)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Lifecycle of a child session. `running` is implicit on spawn; the agent
/// only notifies about it explicitly in the OpenCode variant.
///
/// An unrecognized state decodes to `.other` rather than failing the whole
/// notification — a future terminal state must still stop the row's spinner,
/// which `isTerminal` decides from the raw string.
enum ACPSubagentState: Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case disconnected
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "running", "created", "in_progress": self = .running
        case "completed", "success": self = .completed
        case "failed", "error": self = .failed
        case "cancelled", "canceled", "interrupted": self = .cancelled
        case "disconnected": self = .disconnected
        case let value: self = .other(value)
        }
    }

    var rawValue: String {
        switch self {
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .disconnected: "disconnected"
        case .other(let value): value
        }
    }

    /// Terminal states stop the spinner and retire the Cancel action.
    /// `.other` is treated as still running: a state Alas does not know
    /// about must not silently claim the child has finished.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .disconnected: true
        case .running, .other: false
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = .init(rawValue: try c.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
