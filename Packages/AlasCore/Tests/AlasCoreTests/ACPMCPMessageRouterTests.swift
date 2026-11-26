import Foundation
import Testing
import AlasCore

@Suite("ACP MCP message router")
struct ACPMCPMessageRouterTests {
    /// Records what reaches the server and holds a request until released.
    private actor Server {
        private(set) var received: [Data] = []
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        private var holding: Set<String> = []
        private let reply: @Sendable ([String: Any]) -> Data

        init(reply: @escaping @Sendable ([String: Any]) -> Data) {
            self.reply = reply
        }

        func hold(_ requestId: String) { holding.insert(requestId) }

        func release(_ requestId: String) {
            holding.remove(requestId)
            held.removeValue(forKey: requestId)?.resume()
        }

        func receive(_ body: Data) async -> Data {
            let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            received.append(body)
            if let id = message["id"] as? String, holding.contains(id) {
                await withCheckedContinuation { held[id] = $0 }
            }
            return reply(message)
        }
    }

    private static func echoResult(_ message: [String: Any]) -> Data {
        let id = message["id"] as? String ?? ""
        return Data(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"resultType":"complete","tools":[]}}"#.utf8)
    }

    private static func request(_ requestId: String, id: Int = 1, params: ACPBrokerJSONValue? = nil) -> ACPMCPMessageRequest {
        .init(id: .number(id), params: .init(
            serverId: "alas:s1", requestId: requestId, method: "tools/list", params: params, sessionId: "s1"
        ))
    }

    private static func message(_ body: Data?) throws -> [String: Any] {
        let body = try #require(body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func object(_ result: Result<Data, JSONRPCError>) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: result.get()) as? NSDictionary)
    }

    @Test("forwards a message under its MCP request id and carries the server's outcome")
    func forwardsAndCarries() async throws {
        let server = Server(reply: Self.echoResult)
        let router = ACPMCPMessageRouter()
        await router.register(serverId: "alas:s1") { await server.receive($0) }

        let meta: ACPBrokerJSONValue = .object(["_meta": .object([
            "io.modelcontextprotocol/protocolVersion": .string("2026-07-28"),
        ])])
        let result = await router.handle(Self.request("r1", params: meta))

        let sent = try Self.message(await server.received.first)
        #expect(sent["id"] as? String == "r1")
        #expect(sent["method"] as? String == "tools/list")
        #expect((sent["params"] as? NSDictionary) == ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]])
        #expect(try Self.object(result) == ["result": ["resultType": "complete", "tools": []]])
    }

    @Test("an MCP error is an outcome, carried rather than raised")
    func carriesMCPErrors() async throws {
        let router = ACPMCPMessageRouter()
        await router.register(serverId: "alas:s1") { _ in
            Data(#"{"jsonrpc":"2.0","id":"r1","error":{"code":-32022,"message":"Unsupported protocol version"}}"#.utf8)
        }

        let result = await router.handle(Self.request("r1"))

        #expect(try Self.object(result) == ["error": ["code": -32022, "message": "Unsupported protocol version"]])
    }

    enum Failure: String, CaseIterable, Sendable {
        case unknownServer, backendThrows, replyWithoutOutcome, positionalParams
    }

    @Test("a message without an MCP outcome fails the binding", arguments: Failure.allCases)
    func bindingErrors(_ failure: Failure) async {
        let router = ACPMCPMessageRouter()
        if failure != .unknownServer {
            await router.register(serverId: "alas:s1") { _ in
                if failure == .backendThrows { throw URLError(.cannotConnectToHost) }
                return Data(#"{"jsonrpc":"2.0","id":"r1"}"#.utf8)
            }
        }
        let params: ACPBrokerJSONValue? = failure == .positionalParams ? .array([.string("x")]) : nil

        let result = await router.handle(Self.request("r1", params: params))

        let expected = switch failure {
        case .unknownServer: -33001
        case .backendThrows, .replyWithoutOutcome: -33002
        case .positionalParams: -32602
        }
        guard case .failure(let error) = result else {
            Issue.record("expected a binding error, got \(result)")
            return
        }
        #expect(error.code == expected)
    }

    @Test("an MCP request id stays taken until its reply, while others run alongside")
    func duplicateActiveRequestIds() async throws {
        let server = Server(reply: Self.echoResult)
        await server.hold("r1")
        let router = ACPMCPMessageRouter()
        await router.register(serverId: "alas:s1") { await server.receive($0) }

        let first = Task { await router.handle(Self.request("r1", id: 1)) }
        try await eventually { await server.received.count == 1 }

        let duplicate = await router.handle(Self.request("r1", id: 2))
        let other = await router.handle(Self.request("r2", id: 3))
        guard case .failure(let error) = duplicate else {
            Issue.record("a duplicate active request id must be refused")
            return
        }
        #expect(error.code == -32602)
        #expect(try Self.object(other)["result"] != nil)

        await server.release("r1")
        #expect(try Self.object(await first.value)["result"] != nil)
        // Once answered, the id may be used again.
        #expect(try Self.object(await router.handle(Self.request("r1", id: 4)))["result"] != nil)
    }

    @Test("cancelling the agent's request tells the server which MCP request to stop")
    func cancelNamesTheMCPRequest() async throws {
        let server = Server(reply: Self.echoResult)
        await server.hold("r1")
        let router = ACPMCPMessageRouter()
        await router.register(serverId: "alas:s1") { await server.receive($0) }

        let call = Task { await router.handle(Self.request("r1", id: 7)) }
        try await eventually { await server.received.count == 1 }
        await router.cancel(requestID: .number(7))

        let cancel = try Self.message(await server.received.last)
        #expect(cancel["method"] as? String == "notifications/cancelled")
        #expect(cancel["id"] == nil)
        #expect((cancel["params"] as? NSDictionary) == ["requestId": "r1"])
        await server.release("r1")
        _ = await call.value
    }
}
