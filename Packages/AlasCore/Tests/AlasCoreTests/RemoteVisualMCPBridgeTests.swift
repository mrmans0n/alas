import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

struct RemoteVisualMCPBridgeTests {
    @Test("colliding MCP ids from concurrent exchanges reach their own callers with their JSON type")
    func collidingIdsAreRestoredPerCaller() async throws {
        let harness = BridgeHarness()
        let first = harness.origin(requestId: "r1"), second = harness.origin(requestId: "r2"), third = harness.origin(requestId: "r3")
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, from: first)
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, from: second)
        harness.send(#"{"jsonrpc":"2.0","id":"1","method":"tools/list"}"#, from: third)
        let backend = try await harness.backend(at: 0)
        try await eventually { backend.sentIds.count == 3 }
        #expect(Set(backend.sentIds).count == 3)

        // Answer out of order.
        for (index, tools) in [(2, "c"), (0, "a"), (1, "b")] {
            backend.respond(#"{"jsonrpc":"2.0","id":"\#(backend.sentIds[index])","result":{"tools":"\#(tools)"}}"#)
        }

        try await eventually { await harness.relay.completions.count == 3 }
        let completions = await harness.relay.completions
        #expect(try response(for: first, in: completions) == ["jsonrpc": "2.0", "id": 1, "result": ["tools": "a"]] as NSDictionary)
        #expect(try response(for: second, in: completions) == ["jsonrpc": "2.0", "id": 1, "result": ["tools": "b"]] as NSDictionary)
        let stringId = try response(for: third, in: completions)
        #expect(stringId["id"] as? String == "1")
        await harness.bridge.invalidate()
    }

    @Test("a response held across a lost helper generation never completes the replacement registration")
    func heldResponseNeverReachesReplacement() async throws {
        let harness = BridgeHarness()
        let stale = harness.origin(relayId: "relay-1", generation: 1, requestId: "r1")
        harness.send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"visual_show","arguments":{}}}"#, from: stale)
        let oldBackend = try await harness.backend(at: 0)
        try await eventually { oldBackend.sentIds.count == 1 }

        harness.events.yield(.unavailable)
        harness.events.yield(.available)
        let current = harness.origin(relayId: "relay-2", generation: 2, requestId: "r1")
        harness.send(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#, from: current)
        let newBackend = try await harness.backend(at: 1)
        try await eventually { newBackend.sentIds.count == 1 }
        #expect(oldBackend.terminated)

        oldBackend.respond(#"{"jsonrpc":"2.0","id":"\#(oldBackend.sentIds[0])","result":{"content":[]}}"#)
        newBackend.respond(#"{"jsonrpc":"2.0","id":"\#(newBackend.sentIds[0])","result":{"tools":[]}}"#)

        try await eventually { await harness.relay.completions.count == 1 }
        let completions = await harness.relay.completions
        #expect(completions.map(\.origin) == [current])
        #expect(try response(for: current, in: completions)["result"] as? NSDictionary == ["tools": []] as NSDictionary)
        // Only the replacement's own exchange counts as registration proof.
        #expect(await harness.registrations == 1)
        await harness.bridge.invalidate()
    }

    @Test("only a successful initialize, tools/list, or visual_show proves registration")
    func registrationNeedsGenuineAgentTraffic() async throws {
        let harness = BridgeHarness()
        harness.send("not json", from: harness.origin(requestId: "bad"))
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, from: harness.origin(requestId: "ping"))
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"visual_show","arguments":{}}}"#,
                     from: harness.origin(requestId: "rejected"))
        let backend = try await harness.backend(at: 0)
        try await eventually { backend.sentIds.count == 2 }
        backend.respond(#"{"jsonrpc":"2.0","id":"\#(backend.sentIds[0])","result":{}}"#)
        backend.respond(#"{"jsonrpc":"2.0","id":"\#(backend.sentIds[1])","result":{"isError":true,"content":[]}}"#)
        try await eventually { await harness.relay.completions.count == 3 }
        #expect(await harness.relay.completions.first?.completion == .failed(code: -32700, message: "Parse error"))
        #expect(await harness.registrations == 0)

        harness.send(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{}}"#, from: harness.origin(requestId: "init"))
        try await eventually { backend.sentIds.count == 3 }
        backend.respond(#"{"jsonrpc":"2.0","id":"\#(backend.sentIds[2])","result":{"protocolVersion":"2025-06-18"}}"#)
        try await eventually { await harness.registrations == 1 }
        await harness.bridge.invalidate()
    }

    @Test("revoked authority refuses calls without a backend, and invalidation fails pending calls before closing its route")
    func revocationRefusesAndInvalidationCleansUp() async throws {
        let harness = BridgeHarness()
        let pending = harness.origin(requestId: "pending")
        harness.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, from: pending)
        let backend = try await harness.backend(at: 0)
        try await eventually { backend.sentIds.count == 1 }

        await harness.revoke()
        let refused = harness.origin(requestId: "refused")
        harness.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, from: refused)
        try await eventually { await harness.relay.completions.count == 1 }
        #expect(await harness.relay.completions.map(\.origin) == [refused])
        #expect(backend.sentIds.count == 1)

        await harness.bridge.invalidate()
        try await eventually { await harness.relay.closed == [harness.route] }
        #expect(backend.terminated)
        let completions = await harness.relay.completions
        #expect(completions.map(\.origin) == [refused, pending])
        #expect(completions.allSatisfy {
            $0.completion == .failed(code: -32000, message: "Alas visual relay unavailable")
        })
        #expect(harness.backendCount == 1)
    }
}

private func response(for origin: RemoteMCPRelayOrigin, in completions: [FakeRelay.Completion]) throws -> NSDictionary {
    let completion = try #require(completions.first { $0.origin == origin }?.completion)
    guard case .frame(let data) = completion else {
        Issue.record("Expected a response frame, got \(completion)")
        return [:]
    }
    return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
}

private final class BridgeHarness: Sendable {
    let route = RemoteMCPRouteHandle()
    let relay = FakeRelay()
    let events: AsyncStream<RemoteMCPRelayEvent>.Continuation
    let bridge: RemoteVisualMCPBridge
    private let state = State()

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteMCPRelayEvent.self)
        events = continuation
        let state = state
        bridge = RemoteVisualMCPBridge(
            route: route,
            events: stream,
            relay: relay,
            makeBackend: { state.makeBackend() },
            authorize: { state.authorized },
            onRegistration: { state.noteRegistration() }
        )
        Task { [bridge] in await bridge.start() }
    }

    var backendCount: Int { state.backends.count }
    var registrations: Int { get async { state.registrationCount } }
    func revoke() async { state.authorized = false }

    func origin(relayId: String = "relay-1", generation: Int = 1, requestId: String) -> RemoteMCPRelayOrigin {
        RemoteMCPRelayOrigin(route: route, relayId: relayId, helperGeneration: generation, requestId: requestId)
    }

    func send(_ frame: String, from origin: RemoteMCPRelayOrigin) {
        events.yield(.request(origin: origin, frame: Data(frame.utf8)))
    }

    func backend(at index: Int) async throws -> FakeBackend {
        try await eventually { self.state.backends.count > index }
        return state.backends[index]
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var _backends: [FakeBackend] = []
        private var _authorized = true
        private var _registrations = 0

        var backends: [FakeBackend] { lock.withLock { _backends } }
        var authorized: Bool {
            get { lock.withLock { _authorized } }
            set { lock.withLock { _authorized = newValue } }
        }
        var registrationCount: Int { lock.withLock { _registrations } }

        func makeBackend() -> JSONRPCStdioTransporting {
            let backend = FakeBackend()
            lock.withLock { _backends.append(backend) }
            return backend
        }

        func noteRegistration() { lock.withLock { _registrations += 1 } }
    }
}

private actor FakeRelay: RemoteMCPRouteServing {
    struct Completion: Sendable {
        let origin: RemoteMCPRelayOrigin
        let completion: RemoteMCPRelayCompletion
    }

    private(set) var completions: [Completion] = []
    private(set) var closed: [RemoteMCPRouteHandle] = []

    func completeMCPRoute(origin: RemoteMCPRelayOrigin, completion: RemoteMCPRelayCompletion) async throws {
        completions.append(Completion(origin: origin, completion: completion))
    }

    func closeMCPRoute(_ handle: RemoteMCPRouteHandle) async {
        closed.append(handle)
    }
}

private final class FakeBackend: JSONRPCStdioTransporting, @unchecked Sendable {
    let incoming: AsyncStream<JSONRPCStdioTransport.Incoming>
    private let continuation: AsyncStream<JSONRPCStdioTransport.Incoming>.Continuation
    private let lock = NSLock()
    private var frames: [Data] = []
    private var _terminated = false

    init() {
        (incoming, continuation) = AsyncStream.makeStream(of: JSONRPCStdioTransport.Incoming.self)
    }

    var sentIds: [String] {
        lock.withLock { frames }.compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["id"] as? String
        }
    }

    var terminated: Bool { lock.withLock { _terminated } }

    func start() throws {}

    func send(_ data: Data) throws {
        lock.withLock { frames.append(data) }
    }

    func respond(_ frame: String) {
        continuation.yield(.frame(Data(frame.utf8)))
    }

    /// Like the real transport, a terminated backend may still deliver a
    /// frame it had already written.
    func terminate() {
        lock.withLock { _terminated = true }
    }
}
