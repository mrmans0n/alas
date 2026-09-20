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

    private func startServer(pairing: RemotePairingService, provider: RemoteSessionsProvider = FakeSessionsProvider()) async throws -> (RemoteServer, String) {
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: provider,
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
}
