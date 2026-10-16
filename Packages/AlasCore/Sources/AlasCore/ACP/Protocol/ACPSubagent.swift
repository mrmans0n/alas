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
public struct ACPSubagentSpawn: Codable, Equatable, Sendable {
    public let subagentSessionId: String
    public let name: String?
    public let task: String?
    public let capabilities: ACPSubagentCapabilities
    // The revised form's `subagent_update` is a patch: a member that is
    // present replaces the child's value, `null` included. A repeated
    // earlier-draft spawn only ever adds. None of these are on the wire.

    /// `capabilities` was present (even `null` or `{}`), so it replaces the
    /// child's set — possibly revoking Cancel.
    public var replacesCapabilities = false
    /// `title` / `description` was `null`: the display override is removed.
    public var clearsName = false
    public var clearsTask = false
    /// The state a child registered by this spawn starts in. The earlier
    /// draft implies `running`; a revised announcement without a state
    /// asserts no activity.
    public var initialState: ACPSubagentState = .running

    public init(
        subagentSessionId: String,
        name: String? = nil,
        task: String? = nil,
        capabilities: ACPSubagentCapabilities = .init(),
        replacesCapabilities: Bool = false,
        clearsName: Bool = false,
        clearsTask: Bool = false,
        initialState: ACPSubagentState = .running
    ) {
        self.subagentSessionId = subagentSessionId
        self.name = name
        self.task = task
        self.capabilities = capabilities
        self.replacesCapabilities = replacesCapabilities
        self.clearsName = clearsName
        self.clearsTask = clearsTask
        self.initialState = initialState
    }

    private enum CodingKeys: String, CodingKey {
        case subagentSessionId, name, task, capabilities
    }

    public init(from decoder: Decoder) throws {
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
public struct ACPSubagentCapabilities: Codable, Equatable, Sendable {
    public let cancel: EmptyObject?
    public let close: EmptyObject?

    public init(cancel: EmptyObject? = nil, close: EmptyObject? = nil) {
        self.cancel = cancel
        self.close = close
    }

    public static let cancellable = ACPSubagentCapabilities(cancel: .init())

    public var supportsCancel: Bool { cancel != nil }
    public var supportsClose: Bool { close != nil }

    private enum CodingKeys: String, CodingKey {
        case cancel, close
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cancel = Self.granted(c, .cancel)
        close = Self.granted(c, .close)
    }

    /// The RFD grants a capability with an object (`{}` included); the AIR
    /// draft spells it as a boolean. Anything else means "not supported".
    private static func granted(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> EmptyObject? {
        if (try? c.decodeIfPresent(EmptyObject.self, forKey: key)) != nil { return .init() }
        if (try? c.decodeIfPresent(Bool.self, forKey: key)) == true { return .init() }
        return nil
    }
}

/// `{"sessionUpdate": "subagent_state_update", ...}` on the parent session.
public struct ACPSubagentStateUpdate: Codable, Equatable, Sendable {
    public let subagentSessionId: String
    public let state: ACPSubagentState
    /// Diagnostic text for a failure. The standard ACP `subagent_state_update`
    /// has no such field, so this is nil for it; OpenCode's own status
    /// notification carries one and is normalized onto this field so the
    /// failure reason is not lost once folded into the standard shape.
    public let error: String?

    public init(subagentSessionId: String, state: ACPSubagentState, error: String? = nil) {
        self.subagentSessionId = subagentSessionId
        self.state = state
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case subagentSessionId, state, error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subagentSessionId = try c.decode(String.self, forKey: .subagentSessionId)
        state = try c.decode(ACPSubagentState.self, forKey: .state)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// Lifecycle of a child session. `running` is implicit on spawn; the agent
/// notifies about it explicitly only in the OpenCode variant and the revised
/// RFD form.
///
/// An unrecognized state decodes to `.other` rather than failing the whole
/// notification — a future terminal state must still stop the row's spinner,
/// which `isTerminal` decides from the raw string.
public enum ACPSubagentState: Codable, Equatable, Sendable {
    case running
    /// Foreground work is blocked on the user: a permission or question the
    /// child asked. Still live — not terminal, and still cancellable.
    case requiresAction
    /// The revised form asserts no current activity: the child was announced
    /// without a state, or its state was cleared with `null`. Nothing is
    /// known to be running, so it neither spins nor blocks, but nothing
    /// finished either — any later snapshot replaces it.
    case unconfirmed
    case completed
    case failed
    case cancelled
    case disconnected
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "running", "created", "in_progress": self = .running
        case "requires_action": self = .requiresAction
        case "unconfirmed": self = .unconfirmed
        case "completed", "success": self = .completed
        case "failed", "error": self = .failed
        case "cancelled", "canceled", "interrupted": self = .cancelled
        case "disconnected": self = .disconnected
        case let value: self = .other(value)
        }
    }

    public var rawValue: String {
        switch self {
        case .running: "running"
        case .requiresAction: "requires_action"
        case .unconfirmed: "unconfirmed"
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
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .disconnected, .unconfirmed: true
        case .running, .requiresAction, .other: false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = .init(rawValue: try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
