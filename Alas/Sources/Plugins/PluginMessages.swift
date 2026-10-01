import Foundation

// JSON-RPC 2.0 payloads for plugin API v1. Envelopes reuse `JSONRPCEnvelope`,
// `JSONRPCID`, and `JSONRPCError` from the ACP protocol layer.

struct PluginProjectRef: Codable, Equatable, Sendable {
    let id: String
    let name: String
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

struct PluginPanelVisibleParams: Codable, Equatable, Sendable {
    let panel: String
    let visible: Bool
}

struct PluginClickParams: Codable, Equatable, Sendable {
    let tab: Int
    let region: String
}

struct PluginRegion: Codable, Equatable, Sendable {
    let id: String
    let label: String
    /// `[x, y, w, h]` in frame pixels.
    let rect: [Int]
}

struct PluginRegionsParams: Codable, Equatable, Sendable {
    let tab: Int
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

/// Exactly one of `tab` and `panel` (API 5) says which tree the message is about.
struct PluginViewRenderHeader: Decodable {
    let tab: Int?
    let panel: String?
}

struct PluginViewEventParams: Codable, Equatable, Sendable {
    var tab: Int?
    var panel: String?
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

// API 5.

struct PluginNotifyParams: Decodable, Sendable {
    let title: String
    let body: String?
}

/// `settings/get` result and `settings/changed` params.
struct PluginSettingsPayload: Codable {
    let values: [String: PluginSettingValue]
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
