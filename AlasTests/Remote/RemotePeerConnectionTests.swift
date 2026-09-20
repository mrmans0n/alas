import Testing
import Foundation
@testable import Alas

@MainActor
struct RemotePeerConnectionTests {
    private enum TimeoutError: Error { case timedOut }

    @MainActor
    private final class Events {
        var all: [RemotePeerConnection.Event] = []
        var states: [RemotePeerConnection.State] { all.compactMap { if case .stateChanged(let s) = $0 { return s } else { return nil } } }
        var hellos: [String] { all.compactMap { if case .hello(let id, _, _, _) = $0 { return id } else { return nil } } }
        var origins: [String] { all.compactMap { if case .originChanged(let o) = $0 { return o } else { return nil } } }
        var messages: [RemoteServerMessage] { all.compactMap { if case .message(let m) = $0 { return m } else { return nil } } }
    }

    /// `serverId` is what `/health` reports. Nil reproduces the default
    /// diagnostics snapshot exactly, so it changes nothing for the tests that
    /// do not care; the health-identity tests set it.
    private func startServer(pairing: RemotePairingService,
                             provider: RemoteSessionsProvider = FakeSessionsProvider(),
                             serverId: String? = nil) async throws -> (RemoteServer, String) {
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: provider,
            diagnostics: { port in
                RemoteDiagnosticsSnapshot(appName: "Alas", port: port, addresses: [],
                                          usesPlainHTTP: true, pairedDeviceCount: 0, serverId: serverId)
            },
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A", hubEnabled: false, federationEnabled: true) }
        )
        try server.start(port: 0)
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)
        return (server, "http://127.0.0.1:\(port)")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func fastConfig(localVersion: Int = RemoteProtocolVersion.current) -> RemotePeerConnection.Config {
        var config = RemotePeerConnection.Config()
        config.handshakeTimeout = 2
        config.initialBackoff = 0.2
        config.maxBackoff = 0.5
        config.localProtocolVersion = localVersion
        return config
    }

    @Test func connectsReceivesHelloAcksAndGoesOnline() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        #expect(events.hellos == ["srv-a"])
        #expect(events.origins == [origin])
        #expect(link.lastOrigin == origin)
        #expect(events.states.first == .connecting)
    }

    @Test func fallsBackToTheNextOriginWhenTheFirstIsDead() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: ["http://127.0.0.1:1", origin], lastOrigin: "http://127.0.0.1:1", token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        #expect(link.lastOrigin == origin)
    }

    @Test func rejectedTokenIsUnauthorizedAndStopsRetrying() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: "not-a-token", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .unauthorized }
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(events.states.filter { $0 == .connecting }.count == 1)
    }

    @Test func deadServerIsOfflineAndRetries() async throws {
        let events = Events()
        let link = RemotePeerConnection(origins: ["http://127.0.0.1:1"], lastOrigin: nil, token: "t", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { events.states.filter { $0 == .connecting }.count >= 2 }
        #expect(events.states.contains(.offline))
    }

    @Test func protocolMismatchIsIncompatible() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig(localVersion: 99)) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .incompatible(remoteVersion: RemoteProtocolVersion.current) }
    }

    @Test func forwardsServerMessagesAfterHello() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let provider = FakeSessionsProvider()
        provider.summaries = [RemoteSessionSummary(id: "s1", title: "T", agentId: "claude", status: "idle", canDrive: false)]
        let (server, origin) = try await startServer(pairing: pairing, provider: provider)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        link.send(.listSessions)
        try await waitUntil { !events.messages.isEmpty }
        #expect(events.messages.first == .sessionList(sessions: provider.summaries))
    }

    @Test func disconnectReturnsToIdle() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { _ in }
        link.connect()
        try await waitUntil { link.state == .online }
        link.disconnect()
        #expect(link.state == .idle)
    }

    @Test func disconnectImmediatelyAfterConnectSettlesIdle() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token, config: fastConfig()) { events.all.append($0) }
        link.connect()
        link.disconnect()
        #expect(link.state == .idle)
        // disconnect() clears `runner` and sets .idle synchronously, but the
        // task connect() spawned is still queued and has not run its body
        // yet. Give it a real chance to start — without the cancellation
        // guard at the top of run(), it announces .connecting right back on
        // top of the .idle disconnect() just set, and with `runner` already
        // nil nothing is left to move the state again. A bare `waitUntil`
        // can't catch this: it checks its condition before ever suspending,
        // so it would see the already-idle state and return before the
        // orphaned task got to run at all.
        for _ in 0..<25 {
            await Task.yield()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(link.state == .idle)
        #expect(!events.states.contains(.connecting))
    }

    @Test func aDisconnectedLinkIsNotResurrectedByAnEarlierReconnectTimer() async throws {
        let events = Events()
        let link = RemotePeerConnection(origins: ["http://127.0.0.1:1"], lastOrigin: nil, token: "t", config: fastConfig()) { events.all.append($0) }
        link.connect()
        // First attempt fails and arms a reconnect timer.
        try await waitUntil { link.state == .offline }
        // A connect() while that timer is pending used to drop it without
        // cancelling, so the next failure's timer became the only one
        // disconnect() could reach.
        link.connect()
        try await waitUntil { events.states.filter { $0 == .offline }.count >= 2 }
        link.disconnect()
        #expect(link.state == .idle)
        // Well past both backoff delays: an orphaned timer would have redialled.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(link.state == .idle)
    }

    @Test func healthProbeFromAnUnexpectedServerDoesNotRevokeTheLink() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, origin) = try await startServer(pairing: pairing, serverId: "srv-a")
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: "not-a-token",
                                        expectedServerId: "srv-somewhere-else", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        // The upgrade is refused and the address answers 200, but as a Mac we
        // never paired with — so this is "unreachable peer", not "revoked".
        try await waitUntil { link.state == .offline }
        #expect(!events.states.contains(.unauthorized))
    }

    @Test func helloFromAnotherIdentityIsRefusedAndNeverRetried() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        // The server's `hello` reports "srv-a" (see `startServer`'s identity);
        // this link was written for a different Mac, so the socket must be
        // dropped rather than adopted.
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token,
                                        expectedServerId: "srv-elsewhere", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .identityMismatch(expected: "srv-elsewhere", actual: "srv-a") }
        // Terminal: no online state, no `hello` event handed to the owner, and
        // well past two backoff delays no second attempt.
        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(!events.states.contains(.online))
        #expect(events.hellos.isEmpty)
        #expect(events.states.filter { $0 == .connecting }.count == 1)
    }

    @Test func healthProbeFromTheExpectedServerStillReportsUnauthorized() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let (server, origin) = try await startServer(pairing: pairing, serverId: "srv-a")
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: "not-a-token",
                                        expectedServerId: "srv-a", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .unauthorized }
        #expect(events.states.filter { $0 == .connecting }.count == 1)
    }
}
