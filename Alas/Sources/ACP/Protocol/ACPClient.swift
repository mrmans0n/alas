import Foundation

struct ACPRequest {
    let method: String
    let params: Encodable?
    init(method: String, params: Encodable? = nil) { self.method = method
    self.params = params }
}

struct ACPResponse {
    let body: Data
}

enum ACPClientError: LocalizedError {
    case notRunning
    case noScript(method: String)
    case jsonrpc(JSONRPCError)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:        return "Agent process is not running."
        case .noScript(let m):   return "Mock client has no script for `\(m)`."
        case .jsonrpc(let e):    return "ACP error \(e.code): \(e.message)"
        case .decoding(let s):   return "Failed to decode ACP response: \(s)"
        }
    }
}

protocol ACPClient: AnyObject {
    /// Sends a request and awaits a JSON-RPC response (raw bytes of the `result` field).
    func send(_ request: ACPRequest) async throws -> ACPResponse

    /// Sends a fire-and-forget JSON-RPC notification. Used for spec-
    /// compliant methods that don't reply, e.g. `session/cancel`,
    /// where awaiting a reply would suspend the caller indefinitely.
    func notify(_ request: ACPRequest) async throws

    /// Streaming `session/update` notifications.
    var incomingUpdates: AsyncStream<ACPSessionUpdateParams> { get }

    /// Permission requests (`session/request_permission`). The client owner must
    /// call `respondToPermission(id:decision:)` exactly once per emitted request.
    var permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)> { get }

    /// Filesystem requests (`fs/read_text_file`, `fs/write_text_file`).
    var fileRequests: AsyncStream<ACPFileRequest> { get }

    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse)
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>)

    func shutdown() async
}

enum ACPFileRequest {
    case read(id: JSONRPCID, params: ACPFsReadParams)
    case write(id: JSONRPCID, params: ACPFsWriteParams)
}
