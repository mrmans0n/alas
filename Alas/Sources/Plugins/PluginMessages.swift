import Foundation

// JSON-RPC 2.0 payloads for plugin API v1. Envelopes reuse `JSONRPCEnvelope`,
// `JSONRPCID`, and `JSONRPCError` from the ACP protocol layer.

struct PluginProjectRef: Codable, Equatable, Sendable {
    let id: String
    let name: String
    /// The SSH host of a remote project; absent for a local one.
    var host: String? = nil
}

struct PluginActivateParams: Codable, Equatable, Sendable {
    let api: Int
    let project: PluginProjectRef
    let grants: [PluginCapability]
}

/// `workspace/snapshot` result and `workspace/changed` params.
struct PluginSnapshotPayload: Codable, Equatable, Sendable {
    let snapshot: PluginWorkspaceSnapshot
}

struct PluginWorktreeSwitchParams: Codable, Equatable, Sendable {
    let id: String
}

struct PluginLogParams: Codable, Equatable, Sendable {
    let level: String
    let message: String
}

struct PluginPanelBadgeParams: Decodable, Sendable {
    let panel: String
    let count: Int?
    let dot: Bool?
    let tone: String?
}

/// Encodes as `{}`.
struct PluginEmptyPayload: Codable, Equatable, Sendable {}

struct PluginResponse<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: JSONRPCID
    let result: Result?
    let error: JSONRPCError?
}

/// Enough of any incoming message to route it. Params are decoded separately
/// with `PluginParams` once the method is known.
struct PluginIncomingHeader: Decodable {
    let jsonrpc: String
    let id: JSONRPCID?
    let method: String?
    let error: JSONRPCError?
    /// Whether a `result` key is present, even when its value is `null`.
    let hasResult: Bool

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        // Like `error`, a present `method` must be a string: `null` is malformed, not "absent".
        method = container.contains(.method) ? try container.decode(String.self, forKey: .method) : nil
        // A present `error` must be an error object: a `null` here is malformed, not "absent".
        error = container.contains(.error) ? try container.decode(JSONRPCError.self, forKey: .error) : nil
        hasResult = container.contains(.result)
    }
}

struct PluginParams<Params: Decodable>: Decodable {
    let params: Params
}

struct PluginTickParams: Codable, Equatable, Sendable {
    let dt: Int
}

/// Where one panel is shown: its worktree or run for the locations that have one (API 6).
struct PluginPanelPlace: Hashable, Codable, Sendable {
    let panel: String
    var worktree: String?
    var run: String?
}

struct PluginPanelVisibleParams: Codable, Equatable, Sendable {
    let panel: String
    var worktree: String?
    var run: String?
    let visible: Bool
}

/// A message's target: one of `tab` and, from API 15, `panel`.
struct PluginSurfaceParams: Decodable, Sendable {
    let tab: Int?
    let panel: String?
}

struct PluginTabVisibleParams: Codable, Equatable, Sendable {
    let tab: Int
    let visible: Bool
}

struct PluginClickParams: Codable, Equatable, Sendable {
    var tab: Int?
    var panel: String?
    let region: String
}

struct PluginRegion: Codable, Equatable, Sendable {
    let id: String
    let label: String
    /// `[x, y, w, h]` in frame pixels.
    let rect: [Int]
}

struct PluginRegionsParams: Codable, Equatable, Sendable {
    var tab: Int?
    var panel: String?
    let regions: [PluginRegion]
}

struct PluginSessionFocusParams: Codable, Equatable, Sendable {
    let id: String
}

enum PluginLastMessage: Equatable {
    case unknownSession, none, text(String)
}

struct PluginAgent: Encodable, Equatable {
    let id: String
    let name: String
}

struct PluginLastMessageResult: Encodable {
    let message: String?

    // `null` must be present, not omitted.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey { case message }
}

struct PluginAgentListResult: Encodable {
    let agents: [PluginAgent]
}

enum PluginLastMessageText {
    /// Cuts on a Character boundary so a multi-byte character is never split.
    static func bounded(_ text: String, maxBytes: Int = 4096) -> String {
        var out = ""
        var bytes = 0
        for character in text {
            bytes += character.utf8.count
            if bytes > maxBytes { break }
            out.append(character)
        }
        return out
    }
}

// API 3. `view/render`'s `root` and `storage/set`'s `value` are arbitrary JSON, read with `JSONSerialization`.

/// Exactly one of `tab` and `panel` (API 5) says which tree the message is about. A panel at a location with a
/// worktree or run names it too (API 6).
struct PluginViewRenderHeader: Decodable {
    let tab: Int?
    let panel: String?
    let worktree: String?
    let run: String?
}

struct PluginViewEventParams: Codable, Equatable, Sendable {
    var tab: Int?
    var panel: String?
    var worktree: String?
    var run: String?
    let id: String
    let kind: String
    let value: String?
}

struct PluginTaskStartParams: Codable, Sendable {
    let title: String
    let prompt: String
    let branch: String?
    let agent: String?
}

struct PluginTaskStartResult: Codable, Equatable, Sendable {
    let sessionId: String
    let branch: String
}

struct PluginTaskFailedParams: Codable, Equatable, Sendable {
    let sessionId: String
    let reason: String
}

struct PluginStorageKeyParams: Codable, Sendable {
    let key: String
}

struct PluginStorageKeysResult: Codable, Equatable, Sendable {
    let keys: [String]
}

// API 9.

struct PluginStorageChangedParams: Codable, Equatable, Sendable {
    let scope: String
    let key: String
}

struct PluginPromptsSetParams: Decodable, Sendable {
    struct Prompt: Decodable, Sendable {
        let name: String?
        let description: String?
    }

    let prompts: [Prompt]
}

// API 5.

struct PluginNotifyParams: Decodable, Sendable {
    let title: String
    let body: String?
}

/// `settings/get` result and `settings/changed` params.
struct PluginSettingsPayload: Codable {
    let values: [String: PluginSettingValue]
    /// Keys of the secret settings that hold a value; the values themselves are never sent.
    let secretsSet: [String]

    @MainActor init(_ settings: PluginSettings) {
        values = settings.values()
        secretsSet = settings.declared.filter { $0.kind == .secret && settings.isSecretSet($0.key) }.map(\.key)
    }
}

struct PluginHTTPFetchParams: Decodable, Sendable {
    let method: String
    let url: String
    let headers: [String: String]?
    let body: String?
}

struct PluginHTTPFetchResult: Encodable {
    let status: Int
    let headers: [String: String]
    let body: String
}

struct PluginTimerSetParams: Decodable, Sendable {
    let id: String
    let seconds: Double
    let repeats: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, seconds
        case repeats = "repeat"
    }
}

struct PluginTimerIDParams: Codable, Sendable {
    let id: String
}

// API 6.

struct PluginSessionSendParams: Decodable, Sendable {
    let session: String
    let text: String
}

struct PluginRunStartParams: Decodable, Sendable {
    let worktree: String
    let script: String
}

/// `usage/turns` and `usage/limits` (API 12). Times are epoch milliseconds; `until` is exclusive.
struct PluginUsageParams: Decodable, Sendable {
    let since: Int64
    var until: Int64?
    var limit: Int?
    /// `project` (the default) or `all`.
    var scope: String?
    /// The previous page's `next`.
    var cursor: UsageCursor?
}

struct PluginUsageTurnsResult: Encodable {
    let turns: [UsageTurn]
    let truncated: Bool
    /// Present when truncated: pass it as `cursor` for the next page.
    let next: UsageCursor?
}

struct PluginUsageLimitsResult: Encodable {
    let limits: [UsageLimitEpisode]
    let truncated: Bool
    let next: UsageCursor?
}

struct PluginRunOutputParams: Decodable, Sendable {
    let run: String
}

enum PluginRunOutput: Equatable, Sendable {
    case unknownRun
    case notFinished
    /// The run finished but its output was not kept.
    case unavailable
    case text(String)
}

struct PluginRunOutputResult: Encodable, Equatable {
    let output: String?
    let truncated: Bool

    // `null` must be present, not omitted.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(output, forKey: .output)
        try container.encode(truncated, forKey: .truncated)
    }

    private enum CodingKeys: String, CodingKey { case output, truncated }

    /// The last `maxBytes` of UTF-8 at most, starting on a Unicode scalar boundary.
    static func tail(_ text: String, maxBytes: Int) -> PluginRunOutputResult {
        guard text.utf8.count > maxBytes else { return PluginRunOutputResult(output: text, truncated: false) }
        var start = text.utf8.index(text.utf8.endIndex, offsetBy: -maxBytes)
        while start.samePosition(in: text.unicodeScalars) == nil { text.utf8.formIndex(after: &start) }
        return PluginRunOutputResult(output: String(text.unicodeScalars[start...]), truncated: true)
    }
}

struct PluginReviewCommentParams: Decodable, Equatable, Sendable {
    static let maxBodyBytes = 16 * 1024

    let worktree: String
    /// Relative to the worktree.
    let path: String
    let line: Int
    let body: String

    var isValid: Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 1024
            && !path.split(separator: "/").contains("..")
            && line >= 1
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.utf8.count <= Self.maxBodyBytes
    }
}

// API 7.

struct PluginPromptExpandParams: Codable, Sendable {
    let name: String
    /// What the user typed after the command.
    let args: String
    let session: String
}

struct PluginContextProvideParams: Codable, Sendable {
    let session: String
    let worktree: String
}

/// A response to `prompt/expand` or `context/provide`: `{"text": …}`, or an error.
struct PluginTextResponse: Decodable {
    struct Result: Decodable {
        let text: String?
    }

    var result: Result?
    var error: JSONRPCError?
}
