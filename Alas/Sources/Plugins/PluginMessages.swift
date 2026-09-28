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
}

struct PluginParams<Params: Decodable>: Decodable {
    let params: Params
}
