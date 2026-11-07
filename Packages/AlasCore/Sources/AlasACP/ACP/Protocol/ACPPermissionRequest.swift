import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// `session/request_permission` — server-to-client.
///
/// Wire shape per the ACP spec: `toolCall` is a `ToolCallUpdate` (every
/// field optional) — *not* a full `ToolCall`. The original adapter sends
/// only `{ toolCallId, title, rawInput }`. Decoding into the strict
/// `ACPToolCallPayload` failed silently and the user never saw the prompt.
///
/// `metadata` carries the request's own `_meta` (decoded, not interpreted
/// here — see `ACPPermissionPresentation`). Our adapter forks attach the
/// negotiated `_meta.permissionPresentation`, and older adapters the legacy
/// `_meta.permission` (title/description/defaultToNo). Others omit `_meta`
/// and decode to `nil`.
public struct ACPPermissionRequestParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let toolCall: ACPPermissionToolCall
    public let options: [ACPPermissionOption]
    public let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case sessionId, toolCall, options
        case metadata = "_meta"
    }

    public init(sessionId: String, toolCall: ACPPermissionToolCall, options: [ACPPermissionOption], metadata: AnyCodable? = nil) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        toolCall = try c.decode(ACPPermissionToolCall.self, forKey: .toolCall)
        options = try c.decode([ACPPermissionOption].self, forKey: .options)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }

    /// This request with the diff patch payloads in its tool-call content
    /// marked unnegotiated. Options and `_meta` are unchanged.
    public func markingDiffPatchesUnnegotiated() -> ACPPermissionRequestParams {
        guard let content = toolCall.content else { return self }
        let markedToolCall = ACPPermissionToolCall(
            toolCallId: toolCall.toolCallId,
            title: toolCall.title,
            kind: toolCall.kind,
            status: toolCall.status,
            content: content.map { $0.markingDiffPatchUnnegotiated() },
            locations: toolCall.locations,
            rawInput: toolCall.rawInput,
            rawOutput: toolCall.rawOutput,
            name: toolCall.name,
            metadata: toolCall.metadata)
        return ACPPermissionRequestParams(
            sessionId: sessionId, toolCall: markedToolCall, options: options, metadata: metadata)
    }
}

/// Lenient toolCall payload used inside permission requests. Mirrors the
/// spec's `ToolCallUpdate` — only `toolCallId` is required.
public struct ACPPermissionToolCall: Codable, Equatable, Sendable {
    public let toolCallId: String
    public let title: String?
    public let kind: String?
    public let status: String?
    public let content: [ACPToolCallContent]?
    public let locations: [ACPToolLocation]?
    public let rawInput: AnyCodable?
    public let rawOutput: AnyCodable?
    /// Stable tool identifier (ACP 1.22+). See `ACPToolCallPayload.name`.
    public let name: String?
    /// `_meta.claudeCode.mcpServer` for `mcp__*` calls — see `mcpServerName`.
    public let metadata: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case toolCallId, title, kind, status, content, locations, rawInput, rawOutput, name
        case metadata = "_meta"
    }

    public init(toolCallId: String, title: String? = nil, kind: String? = nil, status: String? = nil,
         content: [ACPToolCallContent]? = nil, locations: [ACPToolLocation]? = nil,
         rawInput: AnyCodable? = nil, rawOutput: AnyCodable? = nil,
         name: String? = nil, metadata: AnyCodable? = nil) {
        self.toolCallId = toolCallId
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.locations = locations
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.name = name
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolCallId = try c.decode(String.self, forKey: .toolCallId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        content = try? c.decodeIfPresent([ACPToolCallContent].self, forKey: .content)
        locations = try? c.decodeIfPresent([ACPToolLocation].self, forKey: .locations)
        rawInput = try? c.decodeIfPresent(AnyCodable.self, forKey: .rawInput)
        rawOutput = try? c.decodeIfPresent(AnyCodable.self, forKey: .rawOutput)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

public struct ACPPermissionOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let optionId: String
    public let name: String
    public let kind: String        // "allow_once" | "allow_always" | "reject_once" | "reject_always"
    /// This option's presentation record — see `presentationDescription`.
    public let metadata: AnyCodable?
    public var id: String { optionId }

    private enum CodingKeys: String, CodingKey {
        case optionId, name, kind
        case metadata = "_meta"
    }

    public init(optionId: String, name: String, kind: String, metadata: AnyCodable? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try c.decode(String.self, forKey: .optionId)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        metadata = try? c.decodeIfPresent(AnyCodable.self, forKey: .metadata)
    }
}

/// `initialize.clientCapabilities._meta` opt-in of a client-neutral presentation
/// contract. The agent's answer isn't read: each record is versioned and only
/// affects display.
public struct ACPPresentationContractDeclaration: Codable, Equatable, Sendable {
    public let version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

/// Shared helpers for reading the loosely-typed `_meta` trees carried by
/// permission requests. Mirrors `ACPContextCompaction`'s extraction style.
private enum ACPPermissionMeta {
    static func object(_ value: AnyCodable?) -> [String: AnyCodable]? {
        guard let value else { return nil }
        if let object = value.value as? [String: AnyCodable] { return object }
        if let object = value.value as? [String: Any] {
            return object.mapValues { $0 as? AnyCodable ?? AnyCodable($0) }
        }
        return nil
    }

    static func nested(_ object: [String: AnyCodable]?, _ key: String) -> [String: AnyCodable]? {
        object.flatMap { $0[key] }.flatMap(self.object)
    }

    static func string(_ object: [String: AnyCodable]?, _ key: String) -> String? {
        object?[key]?.value as? String
    }

    static func int(_ object: [String: AnyCodable]?, _ key: String) -> Int? {
        object?[key]?.value as? Int
    }

    static func bool(_ object: [String: AnyCodable]?, _ key: String) -> Bool? {
        object?[key]?.value as? Bool
    }

    /// The presentation record of a request or option `_meta`: the negotiated
    /// `permissionPresentation`, else the legacy `permission`. A record of any
    /// other version is unknown, so it never hides a readable one.
    static func presentationRecord(_ metadata: AnyCodable?) -> [String: AnyCodable]? {
        let root = object(metadata)
        for key in ["permissionPresentation", "permission"] {
            let record = nested(root, key)
            if int(record, "version") == 1 { return record }
        }
        return nil
    }
}

/// Decoded presentation of a `session/request_permission`. Display hints only:
/// `options` stay what the user can decide. Gated on `version == 1`: missing,
/// malformed, or future-versioned `_meta` decodes to `nil` and the prompt
/// falls back to its plain rendering.
public struct ACPPermissionPresentation: Equatable, Sendable {
    public let title: String?
    public let description: String?
    public let defaultToNo: Bool

    public init?(metadata: AnyCodable?) {
        guard let permission = ACPPermissionMeta.presentationRecord(metadata) else { return nil }
        title = ACPPermissionMeta.string(permission, "title")
        description = ACPPermissionMeta.string(permission, "description")
        defaultToNo = ACPPermissionMeta.bool(permission, "defaultToNo") ?? false
    }
}

extension ACPPermissionOption {
    /// Per-option reason from the option's presentation record.
    public var presentationDescription: String? {
        ACPPermissionMeta.string(ACPPermissionMeta.presentationRecord(metadata), "description")
    }
}

extension ACPPermissionToolCall {
    /// MCP server name from `_meta.claudeCode.mcpServer.name`, shown for
    /// tool calls proxied through an MCP server.
    public var mcpServerName: String? {
        let claudeCode = ACPPermissionMeta.nested(ACPPermissionMeta.object(metadata), "claudeCode")
        let mcpServer = ACPPermissionMeta.nested(claudeCode, "mcpServer")
        return ACPPermissionMeta.string(mcpServer, "name")
    }
}

/// Response: `{ outcome: { outcome: "selected", optionId: "..." } }` or
/// `{ outcome: { outcome: "cancelled" } }`.
public struct ACPPermissionResponse: Codable, Equatable, Sendable {
    public let outcome: Outcome

    public enum Outcome: Codable, Equatable, Sendable {
        case selected(optionId: String)
        case cancelled

        private enum K: String, CodingKey { case outcome, optionId }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            let kind = try c.decode(String.self, forKey: .outcome)
            switch kind {
            case "selected":  self = .selected(optionId: try c.decode(String.self, forKey: .optionId))
            case "cancelled": self = .cancelled
            default:          self = .cancelled
            }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .selected(let id):
                try c.encode("selected", forKey: .outcome)
                try c.encode(id, forKey: .optionId)
            case .cancelled:
                try c.encode("cancelled", forKey: .outcome)
            }
        }
    }

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

extension ACPPermissionToolCall {
    /// ExitPlanMode or a Codex plan review: never remembered, never auto-answered.
    public var isPlanReview: Bool {
        kind == "switch_mode" || toolCallId.hasPrefix("plan-review:")
            || ACPPlanFilePayload.from(metadata: metadata)?.isWellFormed == true
    }
}
