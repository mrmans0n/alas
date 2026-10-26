import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public typealias ACPDurableConsumptionAcknowledgement = @Sendable () -> Void

public struct ACPRequest {
    public let method: String
    public let params: Encodable?
    public let brokerOperationKey: String?

    public init(method: String, params: Encodable? = nil, brokerOperationKey: String? = nil) {
        self.method = method
        self.params = params
        self.brokerOperationKey = brokerOperationKey
    }
}

public struct ACPResponse: Sendable {
    public let body: Data
    public let durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement?

    public init(
        body: Data,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        self.body = body
        self.durableConsumptionAcknowledgement = durableConsumptionAcknowledgement
    }

    public func acknowledgeDurableConsumption() {
        durableConsumptionAcknowledgement?()
    }
}

public enum ACPClientError: LocalizedError, Sendable {
    case notRunning
    case noScript(method: String)
    case jsonrpc(JSONRPCError)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:        return "Agent process is not running."
        case .noScript(let m):   return "Mock client has no script for `\(m)`."
        case .jsonrpc(let e):    return "ACP error \(e.code): \(e.message)"
        case .decoding(let s):   return "Failed to decode ACP response: \(s)"
        }
    }
}

public protocol ACPClient: AnyObject {
    /// Whether repeated requests carrying the same `brokerOperationKey` are
    /// durably deduplicated across connection/process restarts.
    var providesDurableOperationKeyDeduplication: Bool { get }

    /// Sends a request and awaits a JSON-RPC response (raw bytes of the `result` field).
    func send(_ request: ACPRequest) async throws -> ACPResponse

    /// Reports when the request reaches the client's dispatch boundary.
    /// Concrete clients should override this to report their transport
    /// enqueue point; the default preserves ordering at the `send` call.
    func send(
        _ request: ACPRequest,
        onRequestHandoff: @Sendable () -> Void
    ) async throws -> ACPResponse

    /// Sends a fire-and-forget JSON-RPC notification. Used for spec-
    /// compliant methods that don't reply, e.g. `session/cancel`,
    /// where awaiting a reply would suspend the caller indefinitely.
    func notify(_ request: ACPRequest) async throws

    /// Immutable decoder mode for this connection's session updates.
    var sessionUpdateProtocolVersion: ACPProtocolVersion { get }

    /// Raw v2 updates, with explicit caller-owned durable consumption.
    var incomingV2Updates: AsyncStream<ACPV2SessionUpdateDelivery> { get }

    /// Streaming v1 `session/update` notifications.
    var incomingUpdates: AsyncStream<ACPSessionUpdateParams> { get }
    /// Monotonic count of `session/update` notifications yielded to
    /// the active update stream. Runners use this as a drain target when an RPC
    /// response races ahead of already-yielded update notifications.
    var yieldedUpdateCount: Int { get }

    /// Permission requests (`session/request_permission`). The client owner must
    /// call `respondToPermission(id:decision:)` exactly once per emitted request.
    var permissionRequests: AsyncStream<(id: JSONRPCID, params: ACPPermissionRequestParams)> { get }

    /// Inbound `$/cancel_request` notifications (OpenCode v2), carrying the
    /// id of a still-pending `session/request_permission` or
    /// `fs/write_text_file` request the agent wants dropped.
    var cancelRequests: AsyncStream<JSONRPCID> { get }

    /// Ask-user question requests from agent-specific ACP extensions. The
    /// client owner must call `respondToQuestion(id:response:)` exactly once
    /// per emitted request.
    var questionRequests: AsyncStream<ACPQuestionRequest> { get }

    /// Plan-approval requests from Cursor's ACP extension.
    var planRequests: AsyncStream<ACPCursorPlanRequest> { get }

    /// Standard ACP elicitation requests and URL completion notifications.
    var elicitationRequests: AsyncStream<ACPElicitationRequest> { get }
    var elicitationCompletions: AsyncStream<ACPElicitationCompleteParams> { get }

    /// `_auth/status_update` notifications from the shared auth-status ACP
    /// extension. Sent once right after `initialize` and again whenever the
    /// agent's auth state changes. Agents that don't support the extension
    /// simply never yield anything on this stream.
    var authStatusUpdates: AsyncStream<ACPAuthStatusEvent> { get }

    /// `_session/list/changes` notifications of the client-neutral session
    /// index. Agents without a list subscription never yield anything.
    var sessionListChanges: AsyncStream<ACPSessionListChanges> { get }

    /// Filesystem requests (`fs/read_text_file`, `fs/write_text_file`).
    var fileRequests: AsyncStream<ACPFileRequest> { get }

    /// Terminal requests (`terminal/create`, `terminal/output`,
    /// `terminal/wait_for_exit`, `terminal/kill`, `terminal/release`).
    var terminalRequests: AsyncStream<ACPTerminalRequest> { get }
    var advertisesTerminalCapability: Bool { get }

    func respondToPermission(id: JSONRPCID, response: ACPPermissionResponse)
    func respondToQuestion(id: JSONRPCID, response: ACPQuestionResponse)
    func respondToPlan(id: JSONRPCID, response: ACPCursorPlanResponse)
    func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    )
    func respondToFileRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>)
    func respondToTerminalRequest(id: JSONRPCID, result: Result<Data, JSONRPCError>)
    func hasPendingOutboundRequest(id: JSONRPCID) -> Bool

    func detach() async
    func shutdown() async
}

/// Clients with a durable broker boundary can pause a request immediately
/// before transport handoff so queue dispatch provenance is persisted first.
public protocol ACPRequestHandoffPreparing: ACPClient {
    func send(
        _ request: ACPRequest,
        beforeRequestHandoff: @Sendable (ACPBrokerGeneration?) async throws -> Void,
        onRequestHandoff: @Sendable () throws -> Void
    ) async throws -> ACPResponse
}

extension ACPClient {
    public var sessionUpdateProtocolVersion: ACPProtocolVersion { .v1 }

    public var incomingV2Updates: AsyncStream<ACPV2SessionUpdateDelivery> {
        AsyncStream { $0.finish() }
    }

    public var providesDurableOperationKeyDeduplication: Bool { false }

    public var advertisesTerminalCapability: Bool { true }

    public var elicitationRequests: AsyncStream<ACPElicitationRequest> {
        AsyncStream { $0.finish() }
    }

    public var elicitationCompletions: AsyncStream<ACPElicitationCompleteParams> {
        AsyncStream { $0.finish() }
    }

    public var cancelRequests: AsyncStream<JSONRPCID> {
        AsyncStream { $0.finish() }
    }

    public var planRequests: AsyncStream<ACPCursorPlanRequest> {
        AsyncStream { $0.finish() }
    }

    public var authStatusUpdates: AsyncStream<ACPAuthStatusEvent> {
        AsyncStream { $0.finish() }
    }

    public var sessionListChanges: AsyncStream<ACPSessionListChanges> {
        AsyncStream { $0.finish() }
    }

    public func respondToElicitation(
        id: JSONRPCID,
        result: Result<ACPElicitationResponse, JSONRPCError>
    ) {}
    public func respondToPlan(id: JSONRPCID, response: ACPCursorPlanResponse) {}

    public func hasPendingOutboundRequest(id: JSONRPCID) -> Bool { true }

    public func detach() async {
        await shutdown()
    }

    public func send(
        _ request: ACPRequest,
        onRequestHandoff: @Sendable () -> Void
    ) async throws -> ACPResponse {
        onRequestHandoff()
        return try await send(request)
    }
}

public enum ACPFileRequest: Sendable {
    case read(id: JSONRPCID, params: ACPFsReadParams)
    case write(id: JSONRPCID, params: ACPFsWriteParams)
}
