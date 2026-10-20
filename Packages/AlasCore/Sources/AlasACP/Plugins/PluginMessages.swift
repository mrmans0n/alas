import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

// JSON-RPC 2.0 payloads for plugin API v1. Envelopes reuse `JSONRPCEnvelope`,
// `JSONRPCID`, and `JSONRPCError` from the ACP protocol layer.

public struct PluginProjectRef: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// The SSH host of a remote project; absent for a local one.
    public var host: String? = nil

    public init(id: String, name: String, host: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
    }
}

public struct PluginActivateParams: Codable, Equatable, Sendable {
    public let api: Int
    public let project: PluginProjectRef
    public let grants: [PluginCapability]

    public init(api: Int, project: PluginProjectRef, grants: [PluginCapability]) {
        self.api = api
        self.project = project
        self.grants = grants
    }
}

public struct PluginWorktreeSwitchParams: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public struct PluginLogParams: Codable, Equatable, Sendable {
    public let level: String
    public let message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }
}

public struct PluginPanelBadgeParams: Decodable, Sendable {
    public let panel: String
    public let count: Int?
    public let dot: Bool?
    public let tone: String?

    public init(panel: String, count: Int?, dot: Bool?, tone: String?) {
        self.panel = panel
        self.count = count
        self.dot = dot
        self.tone = tone
    }
}

/// Encodes as `{}`.
public struct PluginEmptyPayload: Codable, Equatable, Sendable {
    public init() {
    }}

public struct PluginResponse<Result: Encodable>: Encodable {
    public let jsonrpc = "2.0"
    public let id: JSONRPCID
    public let result: Result?
    public let error: JSONRPCError?

    public init(id: JSONRPCID, result: Result?, error: JSONRPCError?) {
        self.id = id
        self.result = result
        self.error = error
    }
}

/// Enough of any incoming message to route it. Params are decoded separately
/// with `PluginParams` once the method is known.
public struct PluginIncomingHeader: Decodable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String?
    public let error: JSONRPCError?
    /// Whether a `result` key is present, even when its value is `null`.
    public let hasResult: Bool

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, result, error }

    public init(from decoder: Decoder) throws {
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

public struct PluginParams<Params: Decodable>: Decodable {
    public let params: Params

    public init(params: Params) {
        self.params = params
    }
}

public struct PluginTickParams: Codable, Equatable, Sendable {
    public let dt: Int

    public init(dt: Int) {
        self.dt = dt
    }
}

/// Where one panel is shown: its worktree or run for the locations that have one (API 6).
public struct PluginPanelPlace: Hashable, Codable, Sendable {
    public let panel: String
    public var worktree: String?
    public var run: String?

    public init(panel: String, worktree: String? = nil, run: String? = nil) {
        self.panel = panel
        self.worktree = worktree
        self.run = run
    }
}

public struct PluginPanelVisibleParams: Codable, Equatable, Sendable {
    public let panel: String
    public var worktree: String?
    public var run: String?
    public let visible: Bool

    public init(panel: String, worktree: String? = nil, run: String? = nil, visible: Bool) {
        self.panel = panel
        self.worktree = worktree
        self.run = run
        self.visible = visible
    }
}

/// A message's target: one of `tab` and, from API 15, `panel`.
public struct PluginSurfaceParams: Decodable, Sendable {
    public let tab: Int?
    public let panel: String?

    public init(tab: Int?, panel: String?) {
        self.tab = tab
        self.panel = panel
    }
}

public struct PluginTabVisibleParams: Codable, Equatable, Sendable {
    public let tab: Int
    public let visible: Bool

    public init(tab: Int, visible: Bool) {
        self.tab = tab
        self.visible = visible
    }
}

public struct PluginClickParams: Codable, Equatable, Sendable {
    public var tab: Int?
    public var panel: String?
    public let region: String

    public init(tab: Int? = nil, panel: String? = nil, region: String) {
        self.tab = tab
        self.panel = panel
        self.region = region
    }
}

public struct PluginRegion: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    /// `[x, y, w, h]` in frame pixels.
    public let rect: [Int]

    public init(id: String, label: String, rect: [Int]) {
        self.id = id
        self.label = label
        self.rect = rect
    }
}

public struct PluginRegionsParams: Codable, Equatable, Sendable {
    public var tab: Int?
    public var panel: String?
    public let regions: [PluginRegion]

    public init(tab: Int? = nil, panel: String? = nil, regions: [PluginRegion]) {
        self.tab = tab
        self.panel = panel
        self.regions = regions
    }
}

public struct PluginSessionFocusParams: Codable, Equatable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

public enum PluginLastMessage: Equatable, Sendable {
    case unknownSession, none, text(String)
}

public struct PluginAgent: Encodable, Equatable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct PluginLastMessageResult: Encodable, Sendable {
    public let message: String?

    // `null` must be present, not omitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(message, forKey: .message)
    }

    private enum CodingKeys: String, CodingKey { case message }

    public init(message: String?) {
        self.message = message
    }
}

public struct PluginAgentListResult: Encodable, Sendable {
    public let agents: [PluginAgent]

    public init(agents: [PluginAgent]) {
        self.agents = agents
    }
}

public enum PluginLastMessageText: Sendable {
    /// Cuts on a Character boundary so a multi-byte character is never split.
    public static func bounded(_ text: String, maxBytes: Int = 4096) -> String {
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
public struct PluginViewRenderHeader: Decodable, Sendable {
    public let tab: Int?
    public let panel: String?
    public let worktree: String?
    public let run: String?

    public init(tab: Int?, panel: String?, worktree: String?, run: String?) {
        self.tab = tab
        self.panel = panel
        self.worktree = worktree
        self.run = run
    }
}

public struct PluginViewEventParams: Codable, Equatable, Sendable {
    public var tab: Int?
    public var panel: String?
    public var worktree: String?
    public var run: String?
    public let id: String
    public let kind: String
    public let value: String?

    public init(tab: Int? = nil, panel: String? = nil, worktree: String? = nil, run: String? = nil, id: String, kind: String, value: String?) {
        self.tab = tab
        self.panel = panel
        self.worktree = worktree
        self.run = run
        self.id = id
        self.kind = kind
        self.value = value
    }
}

public struct PluginTaskStartParams: Codable, Sendable {
    public let title: String
    public let prompt: String
    public let branch: String?
    public let agent: String?

    public init(title: String, prompt: String, branch: String?, agent: String?) {
        self.title = title
        self.prompt = prompt
        self.branch = branch
        self.agent = agent
    }
}

public struct PluginTaskStartResult: Codable, Equatable, Sendable {
    public let sessionId: String
    public let branch: String

    public init(sessionId: String, branch: String) {
        self.sessionId = sessionId
        self.branch = branch
    }
}

public struct PluginTaskFailedParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let reason: String

    public init(sessionId: String, reason: String) {
        self.sessionId = sessionId
        self.reason = reason
    }
}

public struct PluginStorageKeyParams: Codable, Sendable {
    public let key: String

    public init(key: String) {
        self.key = key
    }
}

public struct PluginStorageKeysResult: Codable, Equatable, Sendable {
    public let keys: [String]

    public init(keys: [String]) {
        self.keys = keys
    }
}

// API 9.

public struct PluginStorageChangedParams: Codable, Equatable, Sendable {
    public let scope: String
    public let key: String

    public init(scope: String, key: String) {
        self.scope = scope
        self.key = key
    }
}

public struct PluginPromptsSetParams: Decodable, Sendable {
    public struct Prompt: Decodable, Sendable {
        public let name: String?
        public let description: String?

        public init(name: String?, description: String?) {
            self.name = name
            self.description = description
        }
    }

    public let prompts: [Prompt]

    public init(prompts: [Prompt]) {
        self.prompts = prompts
    }
}

// API 5.

public struct PluginNotifyParams: Decodable, Sendable {
    public let title: String
    public let body: String?

    public init(title: String, body: String?) {
        self.title = title
        self.body = body
    }
}

/// `settings/get` result and `settings/changed` params.
public struct PluginSettingsPayload: Codable, Sendable {
    public let values: [String: PluginSettingValue]
    /// Keys of the secret settings that hold a value; the values themselves are never sent.
    public let secretsSet: [String]

    @MainActor public init(_ settings: PluginSettings) {
        values = settings.values()
        secretsSet = settings.declared.filter { $0.kind == .secret && settings.isSecretSet($0.key) }.map(\.key)
    }
}

public struct PluginHTTPFetchParams: Decodable, Sendable {
    public let method: String
    public let url: String
    public let headers: [String: String]?
    public let body: String?

    public init(method: String, url: String, headers: [String: String]?, body: String?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct PluginHTTPFetchResult: Encodable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public struct PluginTimerSetParams: Decodable, Sendable {
    public let id: String
    public let seconds: Double
    public let repeats: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, seconds
        case repeats = "repeat"
    }

    public init(id: String, seconds: Double, repeats: Bool?) {
        self.id = id
        self.seconds = seconds
        self.repeats = repeats
    }
}

public struct PluginTimerIDParams: Codable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

// API 6.

public struct PluginSessionSendParams: Decodable, Sendable {
    public let session: String
    public let text: String

    public init(session: String, text: String) {
        self.session = session
        self.text = text
    }
}

public struct PluginRunStartParams: Decodable, Sendable {
    public let worktree: String
    public let script: String

    public init(worktree: String, script: String) {
        self.worktree = worktree
        self.script = script
    }
}

/// `usage/turns` and `usage/limits` (API 12). Times are epoch milliseconds; `until` is exclusive.
public struct PluginUsageParams: Decodable, Sendable {
    public let since: Int64
    public var until: Int64?
    public var limit: Int?
    /// `project` (the default) or `all`.
    public var scope: String?
    /// The previous page's `next`.
    public var cursor: UsageCursor?

    public init(since: Int64, until: Int64? = nil, limit: Int? = nil, scope: String? = nil, cursor: UsageCursor? = nil) {
        self.since = since
        self.until = until
        self.limit = limit
        self.scope = scope
        self.cursor = cursor
    }
}

public struct PluginUsageTurnsResult: Encodable, Sendable {
    public let turns: [UsageTurn]
    public let truncated: Bool
    /// Present when truncated: pass it as `cursor` for the next page.
    public let next: UsageCursor?

    public init(turns: [UsageTurn], truncated: Bool, next: UsageCursor?) {
        self.turns = turns
        self.truncated = truncated
        self.next = next
    }
}

public struct PluginUsageLimitsResult: Encodable, Sendable {
    public let limits: [UsageLimitEpisode]
    public let truncated: Bool
    public let next: UsageCursor?

    public init(limits: [UsageLimitEpisode], truncated: Bool, next: UsageCursor?) {
        self.limits = limits
        self.truncated = truncated
        self.next = next
    }
}

public struct PluginRunOutputParams: Decodable, Sendable {
    public let run: String

    public init(run: String) {
        self.run = run
    }
}

public enum PluginRunOutput: Equatable, Sendable {
    case unknownRun
    case notFinished
    /// The run finished but its output was not kept.
    case unavailable
    case text(String)
}

public struct PluginRunOutputResult: Encodable, Equatable, Sendable {
    public let output: String?
    public let truncated: Bool

    // `null` must be present, not omitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(output, forKey: .output)
        try container.encode(truncated, forKey: .truncated)
    }

    private enum CodingKeys: String, CodingKey { case output, truncated }

    /// The last `maxBytes` of UTF-8 at most, starting on a Unicode scalar boundary.
    public static func tail(_ text: String, maxBytes: Int) -> PluginRunOutputResult {
        guard text.utf8.count > maxBytes else { return PluginRunOutputResult(output: text, truncated: false) }
        var start = text.utf8.index(text.utf8.endIndex, offsetBy: -maxBytes)
        while start.samePosition(in: text.unicodeScalars) == nil { text.utf8.formIndex(after: &start) }
        return PluginRunOutputResult(output: String(text.unicodeScalars[start...]), truncated: true)
    }

    public init(output: String?, truncated: Bool) {
        self.output = output
        self.truncated = truncated
    }
}

public struct PluginReviewCommentParams: Decodable, Equatable, Sendable {
    public static let maxBodyBytes = 16 * 1024

    public let worktree: String
    /// Relative to the worktree.
    public let path: String
    public let line: Int
    public let body: String

    public var isValid: Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 1024
            && !path.split(separator: "/").contains("..")
            && line >= 1
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.utf8.count <= Self.maxBodyBytes
    }

    public init(worktree: String, path: String, line: Int, body: String) {
        self.worktree = worktree
        self.path = path
        self.line = line
        self.body = body
    }
}

// API 7.

public struct PluginPromptExpandParams: Codable, Sendable {
    public let name: String
    /// What the user typed after the command.
    public let args: String
    public let session: String

    public init(name: String, args: String, session: String) {
        self.name = name
        self.args = args
        self.session = session
    }
}

public struct PluginContextProvideParams: Codable, Sendable {
    public let session: String
    public let worktree: String

    public init(session: String, worktree: String) {
        self.session = session
        self.worktree = worktree
    }
}

/// A response to `prompt/expand` or `context/provide`: `{"text": …}`, or an error.
public struct PluginTextResponse: Decodable, Sendable {
    public struct Result: Decodable, Sendable {
        public let text: String?

        public init(text: String?) {
            self.text = text
        }
    }

    public var result: Result?
    public var error: JSONRPCError?

    public init(result: Result? = nil, error: JSONRPCError? = nil) {
        self.result = result
        self.error = error
    }
}
