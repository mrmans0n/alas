import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// The documented facts a subagent carries on its synthetic parent-transcript
/// row, and the projection in both directions.
///
/// A subagent occupies one row of the parent transcript. That row is a
/// `.toolCall` message rather than a new `ACPMessage` case on purpose — the
/// same trick context compaction uses (`ACPContextCompaction`). It means the
/// row persists, mirrors to the remote web client, forks and hydrates through
/// the paths that already exist, and the child's live transcript hangs off
/// `ACPSession.subagents` keyed by the id stored here.
public struct ACPSubagentRowDescriptor: Equatable, Sendable {
    public static let metadataKey = "subagent"
    public static let version = 1

    public let subagentSessionId: String
    public let name: String?
    public let task: String?
    public let state: ACPSubagentState
    public let capabilities: ACPSubagentCapabilities
    /// Diagnostic text from the most recent failure, when the agent
    /// provided one. Carried in the row's own metadata so it survives
    /// persistence and hydration rather than living only in memory.
    public let lastError: String?
    /// The child's own last observed config snapshot and directories. Absent
    /// from rows written before they were tracked, which decode as empty.
    /// Whether they were confirmed live is deliberately not stored.
    public let configOptions: [ACPConfigOption]
    public let cwd: String?
    public let additionalDirectories: [String]
    /// Both views of each delegation message this child sent or received,
    /// joined. Absent from rows written before links were tracked.
    public let links: [ACPDelegationLink]

    public init(
        subagentSessionId: String,
        name: String?,
        task: String?,
        state: ACPSubagentState,
        capabilities: ACPSubagentCapabilities,
        lastError: String? = nil,
        configOptions: [ACPConfigOption] = [],
        cwd: String? = nil,
        additionalDirectories: [String] = [],
        links: [ACPDelegationLink] = []
    ) {
        self.subagentSessionId = subagentSessionId
        self.name = name
        self.task = task
        self.state = state
        self.capabilities = capabilities
        self.lastError = lastError
        self.configOptions = configOptions
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.links = links
    }

    /// Reads the descriptor back off a transcript row. Returns nil for every
    /// ordinary tool call, so the renderer can use it as the discriminator.
    public init?(toolCall: ACPMessage.ToolCall) {
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
        lastError = Self.string(facts["lastError"])
        configOptions = Self.decoded([ACPConfigOption].self, facts["config"]) ?? []
        cwd = Self.string(facts["cwd"])
        additionalDirectories = Self.strings(facts["additionalDirectories"])
        links = Self.decoded([ACPDelegationLink].self, facts["links"]) ?? []
        let capabilities = Self.object(facts["capabilities"]) ?? [:]
        self.capabilities = .init(
            cancel: Self.bool(capabilities["cancel"]) == true ? .init() : nil,
            close: Self.bool(capabilities["close"]) == true ? .init() : nil
        )
    }

    public static func toolCallId(subagentSessionId: String) -> String {
        "subagent:\(subagentSessionId)"
    }

    public var toolCallId: String { Self.toolCallId(subagentSessionId: subagentSessionId) }

    /// Tool-call status mirroring the child's lifecycle, so anything that
    /// reasons about status (spinners, `isFinalStatus`, remote mirrors) sees
    /// a live subagent as in-progress and a finished one as done.
    public var toolCallStatus: String {
        switch state {
        case .running, .requiresAction, .other: "in_progress"
        case .completed, .unconfirmed: "completed"
        case .failed, .disconnected: "failed"
        case .cancelled: "cancelled"
        }
    }

    public var metadata: AnyCodable {
        var facts: [String: AnyCodable] = [
            "version": AnyCodable(Self.version),
            "id": AnyCodable(subagentSessionId),
            "state": AnyCodable(state.rawValue)
        ]
        if let name { facts["name"] = AnyCodable(name) }
        if let task { facts["task"] = AnyCodable(task) }
        if let lastError { facts["lastError"] = AnyCodable(lastError) }
        if !configOptions.isEmpty, let json = Self.json(configOptions) { facts["config"] = json }
        if let cwd { facts["cwd"] = AnyCodable(cwd) }
        if !additionalDirectories.isEmpty {
            facts["additionalDirectories"] = AnyCodable(additionalDirectories.map(AnyCodable.init))
        }
        if !links.isEmpty, let json = Self.json(links) { facts["links"] = json }
        var capabilityFacts: [String: AnyCodable] = [:]
        if capabilities.supportsCancel { capabilityFacts["cancel"] = AnyCodable(true) }
        if capabilities.supportsClose { capabilityFacts["close"] = AnyCodable(true) }
        if !capabilityFacts.isEmpty { facts["capabilities"] = AnyCodable(capabilityFacts) }
        return AnyCodable([Self.metadataKey: AnyCodable(facts)])
    }

    /// The parent-transcript row standing for this subagent.
    public func toolCall(
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

    private static func json<Value: Encodable>(_ value: Value) -> AnyCodable? {
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return AnyCodable(json)
    }

    private static func decoded<Value: Decodable>(_ type: Value.Type, _ value: AnyCodable?) -> Value? {
        value
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func object(_ value: AnyCodable?) -> [String: AnyCodable]? {
        guard let value else { return nil }
        if let object = value.value as? [String: AnyCodable] { return object }
        if let object = value.value as? [String: Any] { return object.mapValues { AnyCodable($0) } }
        return nil
    }

    private static func string(_ value: AnyCodable?) -> String? {
        value?.value as? String
    }

    private static func strings(_ value: AnyCodable?) -> [String] {
        if let values = value?.value as? [AnyCodable] { return values.compactMap { $0.value as? String } }
        if let values = value?.value as? [Any] { return values.compactMap { $0 as? String } }
        return []
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
