import Foundation

/// The documented facts a subagent carries on its synthetic parent-transcript
/// row, and the projection in both directions.
///
/// A subagent occupies one row of the parent transcript. That row is a
/// `.toolCall` message rather than a new `ACPMessage` case on purpose — the
/// same trick context compaction uses (`ACPContextCompaction`). It means the
/// row persists, mirrors to the remote web client, forks and hydrates through
/// the paths that already exist, and the child's live transcript hangs off
/// `ACPSession.subagents` keyed by the id stored here.
struct ACPSubagentRowDescriptor: Equatable, Sendable {
    static let metadataKey = "subagent"
    static let version = 1

    let subagentSessionId: String
    let name: String?
    let task: String?
    let state: ACPSubagentState
    let capabilities: ACPSubagentCapabilities

    init(
        subagentSessionId: String,
        name: String?,
        task: String?,
        state: ACPSubagentState,
        capabilities: ACPSubagentCapabilities
    ) {
        self.subagentSessionId = subagentSessionId
        self.name = name
        self.task = task
        self.state = state
        self.capabilities = capabilities
    }

    /// Reads the descriptor back off a transcript row. Returns nil for every
    /// ordinary tool call, so the renderer can use it as the discriminator.
    init?(toolCall: ACPMessage.ToolCall) {
        guard let root = Self.object(toolCall.metadata),
              let raw = root[Self.metadataKey],
              let facts = Self.object(raw),
              Self.int(facts["version"]) == Self.version,
              let id = Self.string(facts["id"])
        else { return nil }
        subagentSessionId = id
        name = Self.string(facts["name"])
        task = Self.string(facts["task"])
        state = Self.string(facts["state"]).map(ACPSubagentState.init(rawValue:)) ?? .running
        let capabilities = Self.object(facts["capabilities"]) ?? [:]
        self.capabilities = .init(
            cancel: Self.bool(capabilities["cancel"]) == true ? .init() : nil,
            close: Self.bool(capabilities["close"]) == true ? .init() : nil
        )
    }

    static func toolCallId(subagentSessionId: String) -> String {
        "subagent:\(subagentSessionId)"
    }

    var toolCallId: String { Self.toolCallId(subagentSessionId: subagentSessionId) }

    /// Tool-call status mirroring the child's lifecycle, so anything that
    /// reasons about status (spinners, `isFinalStatus`, remote mirrors) sees
    /// a live subagent as in-progress and a finished one as done.
    var toolCallStatus: String {
        switch state {
        case .running, .other: "in_progress"
        case .completed: "completed"
        case .failed, .disconnected: "failed"
        case .cancelled: "cancelled"
        }
    }

    var metadata: AnyCodable {
        var facts: [String: AnyCodable] = [
            "version": AnyCodable(Self.version),
            "id": AnyCodable(subagentSessionId),
            "state": AnyCodable(state.rawValue)
        ]
        if let name { facts["name"] = AnyCodable(name) }
        if let task { facts["task"] = AnyCodable(task) }
        var capabilityFacts: [String: AnyCodable] = [:]
        if capabilities.supportsCancel { capabilityFacts["cancel"] = AnyCodable(true) }
        if capabilities.supportsClose { capabilityFacts["close"] = AnyCodable(true) }
        if !capabilityFacts.isEmpty { facts["capabilities"] = AnyCodable(capabilityFacts) }
        return AnyCodable([Self.metadataKey: AnyCodable(facts)])
    }

    /// The parent-transcript row standing for this subagent.
    func toolCall(
        executionStartedAt: Date?,
        executionFinishedAt: Date?
    ) -> ACPMessage.ToolCall {
        .init(
            toolCallId: toolCallId,
            title: name ?? "Subagent",
            kind: "think",
            status: toolCallStatus,
            content: task ?? "",
            preview: task.flatMap { $0.isEmpty ? nil : $0 },
            metadata: metadata,
            executionStartedAt: executionStartedAt,
            executionFinishedAt: executionFinishedAt)
    }

    // MARK: - AnyCodable readers

    private static func object(_ value: AnyCodable?) -> [String: AnyCodable]? {
        guard let value else { return nil }
        if let object = value.value as? [String: AnyCodable] { return object }
        if let object = value.value as? [String: Any] { return object.mapValues { AnyCodable($0) } }
        return nil
    }

    private static func string(_ value: AnyCodable?) -> String? {
        value?.value as? String
    }

    private static func int(_ value: AnyCodable?) -> Int? {
        value?.value as? Int
    }

    private static func bool(_ value: AnyCodable?) -> Bool? {
        if let bool = value?.value as? Bool { return bool }
        if let number = value?.value as? Int { return number != 0 }
        return nil
    }
}
