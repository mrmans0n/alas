import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// `mcp/message` from the agent (MCP-over-ACP): one MCP message for a server
/// the client serves over this connection, registered as `type: "acp"`.
public struct ACPMCPMessageParams: Codable, Equatable, Sendable {
    /// The registration the message is for.
    public let serverId: String
    /// The MCP request's own id, fresh for each operation.
    public let requestId: String
    /// The MCP method, e.g. `tools/call`.
    public let method: String
    public let params: ACPBrokerJSONValue?
    /// The ACP session whose work caused the request, when the agent knows it.
    public let sessionId: String?
    /// The tool call the request belongs to, when the agent knows it.
    public let toolCallId: String?

    public init(
        serverId: String,
        requestId: String,
        method: String,
        params: ACPBrokerJSONValue? = nil,
        sessionId: String? = nil,
        toolCallId: String? = nil
    ) {
        self.serverId = serverId
        self.requestId = requestId
        self.method = method
        self.params = params
        self.sessionId = sessionId
        self.toolCallId = toolCallId
    }
}

public struct ACPMCPMessageRequest: Sendable {
    public let id: JSONRPCID
    public let params: ACPMCPMessageParams

    public init(id: JSONRPCID, params: ACPMCPMessageParams) {
        self.id = id
        self.params = params
    }
}

/// Answers `mcp/message` for the servers Alas serves over ACP by forwarding
/// each message to the backend registered under its `serverId`, and turns
/// the backend's reply into the binding's result: `{"result": …}` or
/// `{"error": …}` for the MCP outcome. An outer error means there is no MCP
/// outcome at all (unknown registration, failed backend, malformed message).
public actor ACPMCPMessageRouter {
    /// Sends one MCP JSON-RPC message and returns the server's reply body,
    /// empty for a notification.
    public typealias Backend = @Sendable (Data) async throws -> Data

    private struct Active: Hashable {
        let serverId: String
        let requestId: String
    }

    private var backends: [String: (token: UUID, backend: Backend)] = [:]
    private var active: [Active: JSONRPCID] = [:]

    public init() {}

    /// Serves `serverId` with `backend` from now on, replacing any earlier
    /// registration. Returns the token that unregisters this one.
    @discardableResult
    public func register(serverId: String, backend: @escaping Backend) -> UUID {
        let token = UUID()
        backends[serverId] = (token, backend)
        return token
    }

    /// Stops serving `serverId`, unless a later registration replaced the
    /// one `token` names: a session's server id outlives each attach.
    public func unregister(serverId: String, token: UUID) {
        guard backends[serverId]?.token == token else { return }
        backends[serverId] = nil
    }

    public func handle(_ request: ACPMCPMessageRequest) async -> Result<Data, JSONRPCError> {
        let message = request.params
        guard let backend = backends[message.serverId]?.backend else {
            return .failure(.init(code: -33001, message: "MCP server registration unavailable", data: nil))
        }
        let key = Active(serverId: message.serverId, requestId: message.requestId)
        guard active[key] == nil else {
            return .failure(.init(code: -32602, message: "MCP request id already active", data: nil))
        }
        var envelope: [String: ACPBrokerJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string(message.requestId),
            "method": .string(message.method),
        ]
        if let params = message.params, params != .null {
            guard case .object = params else {
                return .failure(.init(code: -32602, message: "MCP params must be an object", data: nil))
            }
            envelope["params"] = params
        }
        active[key] = request.id
        defer { active[key] = nil }
        let reply: Data
        do {
            reply = try await backend(try ACPBrokerJSONValue.object(envelope).data)
        } catch {
            return .failure(Self.backendFailure("\(error.localizedDescription)"))
        }
        guard case .object(let object)? = try? JSONDecoder().decode(ACPBrokerJSONValue.self, from: reply) else {
            return .failure(Self.backendFailure("the MCP server sent no reply"))
        }
        // The binding prefers `result` when a reply carries both.
        if let result = object["result"] {
            return Self.carrier(["result": result])
        }
        if let error = object["error"] {
            return Self.carrier(["error": error])
        }
        return .failure(Self.backendFailure("the MCP server's reply has no outcome"))
    }

    /// Asks the backend to stop the request the agent sent as `requestID`,
    /// best effort. Its `mcp/message` still gets whatever the server answers.
    public func cancel(requestID: JSONRPCID) async {
        guard let key = active.first(where: { $0.value == requestID })?.key,
              let backend = backends[key.serverId]?.backend
        else { return }
        let notification: ACPBrokerJSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/cancelled"),
            "params": .object(["requestId": .string(key.requestId)]),
        ])
        guard let body = try? notification.data else { return }
        _ = try? await backend(body)
    }

    private static func carrier(_ object: [String: ACPBrokerJSONValue]) -> Result<Data, JSONRPCError> {
        do {
            return .success(try ACPBrokerJSONValue.object(object).data)
        } catch {
            return .failure(backendFailure("the MCP outcome could not be encoded"))
        }
    }

    private static func backendFailure(_ reason: String) -> JSONRPCError {
        .init(code: -33002, message: "MCP backend failed: \(reason)", data: nil)
    }
}

/// A router backend that posts each message to an `alas mcp --http` server.
public enum ACPMCPHTTPBackend {
    public enum Failure: LocalizedError {
        case invalidURL
        case status(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "invalid MCP server URL"
            case .status(let code): "the MCP server answered HTTP \(code)"
            }
        }
    }

    /// Tool calls such as `session_wait` stay silent for minutes, so the
    /// request may idle far longer than URLSession's default minute.
    static let requestTimeout: TimeInterval = 3600

    public static func backend(
        endpoint: BuiltInAlasMCP.HTTPEndpoint,
        session: URLSession = .shared
    ) -> ACPMCPMessageRouter.Backend {
        { body in
            guard let url = URL(string: endpoint.url) else { throw Failure.invalidURL }
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.httpMethod = "POST"
            request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 202 else { throw Failure.status(status) }
            return data
        }
    }
}
