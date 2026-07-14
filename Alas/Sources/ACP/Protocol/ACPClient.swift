import Foundation

typealias ACPDurableConsumptionAcknowledgement = @Sendable () -> Void

struct ACPRequest {
    let method: String
    let params: Encodable?
    init(method: String, params: Encodable? = nil) { self.method = method
    self.params = params }
}

struct ACPResponse {
    let body: Data
    let durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement?

    init(
        body: Data,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        self.body = body
        self.durableConsumptionAcknowledgement = durableConsumptionAcknowledgement
    }

    func acknowledgeDurableConsumption() {
        durableConsumptionAcknowledgement?()
    }
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
    /// Monotonic count of `session/update` notifications yielded to
    /// `incomingUpdates`. Runners use this as a drain target when an RPC
    /// response races ahead of already-yielded update notifications.
    var yieldedUpdateCount: Int { get }

    /// Permission requests (`session/request_permission`). The client owner must
    /// call `respondToPermission(id:decision:)` exactly once per emitted request.
    var permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)> { get }

    /// Ask-user question requests from agent-specific ACP extensions. The
    /// client owner must call `respondToQuestion(id:response:)` exactly once
    /// per emitted request.
    var questionRequests: AsyncStream<ACPQuestionRequest> { get }

    /// Standard ACP elicitation requests and URL completion notifications.
    var elicitationRequests: AsyncStream<ACPElicitationRequest> { get }
    var elicitationCompletions: AsyncStream<ACPElicitationCompleteParams> { get }

    /// Filesystem requests (`fs/read_text_file`, `fs/write_text_file`).
    var fileRequests: AsyncStream<ACPFileRequest> { get }

    /// Terminal requests (`terminal/create`, `terminal/output`,
    /// `terminal/wait_for_exit`, `terminal/kill`, `terminal/release`).
    var terminalRequests: AsyncStream<ACPTerminalRequest> { get }

    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse)
    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse)
    func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    )
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>)
    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>)
    func hasPendingOutboundRequest(id: JSONRPCID) -> Bool

    func shutdown() async
}

extension ACPClient {
    var elicitationRequests: AsyncStream<ACPElicitationRequest> {
        AsyncStream { $0.finish() }
    }

    var elicitationCompletions: AsyncStream<ACPElicitationCompleteParams> {
        AsyncStream { $0.finish() }
    }

    func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    ) {}

    func hasPendingOutboundRequest(id: JSONRPCID) -> Bool { true }
}

enum ACPFileRequest {
    case read(id: JSONRPCID, params: ACPFsReadParams)
    case write(id: JSONRPCID, params: ACPFsWriteParams)
}
