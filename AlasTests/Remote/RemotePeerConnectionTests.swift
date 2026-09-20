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
        var helloNames: [String] { all.compactMap { if case .hello(_, let name, _, _) = $0 { return name } else { return nil } } }
        var helloVersions: [Int] { all.compactMap { if case .hello(_, _, let v, _) = $0 { return v } else { return nil } } }
        /// Without this the `federationEnabled` the link forwards is untested,
        /// so mixing up the `hello` frame's trailing fields stays green.
        var helloFederation: [Bool] { all.compactMap { if case .hello(_, _, _, let f) = $0 { return f } else { return nil } } }
        var origins: [String] { all.compactMap { if case .originChanged(let o) = $0 { return o } else { return nil } } }
        var messages: [RemoteServerMessage] { all.compactMap { if case .message(let m) = $0 { return m } else { return nil } } }
    }

    /// `serverId` is what `/health` reports. Nil reproduces the default
    /// diagnostics snapshot exactly, so it changes nothing for the tests that
    /// do not care; the health-identity tests set it.
    private func startServer(pairing: RemotePairingService,
                             provider: RemoteSessionsProvider = FakeSessionsProvider(),
                             serverId: String? = nil,
                             helloServerId: String = "srv-a") async throws -> (RemoteServer, String) {
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: provider,
            diagnostics: { port in
                RemoteDiagnosticsSnapshot(appName: "Alas", port: port, addresses: [],
                                          usesPlainHTTP: true, pairedDeviceCount: 0, serverId: serverId)
            },
            identity: { RemoteServerIdentity(serverId: helloServerId, name: "Mac A", hubEnabled: false, federationEnabled: true) }
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
        #expect(events.helloNames == ["Mac A"])
        #expect(events.helloVersions == [RemoteProtocolVersion.current])
        // `startServer`'s identity sets federationEnabled: true.
        #expect(events.helloFederation == [true])
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

    // The version check ran BEFORE the identity check, so a stale
    // origin reassigned to an unrelated Alas instance running an
    // incompatible version reported .incompatible — terminal, no reconnect —
    // without ever noticing the identity was ALSO wrong, masking a
    // recoverable "wrong Mac" situation as an unrecoverable "wrong version"
    // one. Both conditions are made true for the SAME origin here: if the
    // version check still ran first, this would settle on `.incompatible`
    // instead.
    @Test func anOriginWithBothTheWrongIdentityAndAnIncompatibleVersionReportsIdentityMismatch() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (server, origin) = try await startServer(pairing: pairing)   // hello reports "srv-a"
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token,
                                        expectedServerId: "srv-elsewhere", config: fastConfig(localVersion: 99)) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .identityMismatch(expected: "srv-elsewhere", actual: "srv-a") }
        #expect(!events.states.contains { if case .incompatible = $0 { return true } else { return false } })
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

    // A refused upgrade looks identical whether the token was genuinely
    // revoked or the peer merely has federation off right now — but only the
    // first should ever stop the link from retrying. `.alasInstance` because
    // the authorize-time federation gate (RemoteServer.accept) only applies
    // to peer devices, not browsers.
    @Test func federationDisabledOnThePeerIsRetryableNotUnauthorized() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let result = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        var federationEnabled = false
        let server = RemoteServer(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            provider: FakeSessionsProvider(),
            identity: { RemoteServerIdentity(serverId: "srv-a", name: "Mac A", hubEnabled: false, federationEnabled: federationEnabled) }
        )
        try server.start(port: 0)
        defer { server.stop() }
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)
        let origin = "http://127.0.0.1:\(port)"

        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: result.token,
                                        expectedServerId: "srv-a", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        // The upgrade is refused (federation is off there) and /health
        // confirms it's really the expected Mac — but that must not read as
        // a revocation.
        try await waitUntil { events.states.filter { $0 == .connecting }.count >= 2 }
        #expect(!events.states.contains(.unauthorized))
        #expect(!events.states.contains(.online))

        // The other Mac's owner flips the flag back on: the very next retry
        // must succeed, proving the link never gave up.
        federationEnabled = true
        try await waitUntil { link.state == .online }
    }

    @Test func helloFromAnotherIdentityIsRefusedButRetriesLater() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        // The server's `hello` reports "srv-a" (see `startServer`'s identity);
        // this link was written for a different Mac, so the socket must be
        // dropped rather than adopted. With only this one origin the mismatch
        // recurs every attempt, but it must still retry rather than dead-end:
        // the same address could later be reassigned back to the real peer.
        let (server, origin) = try await startServer(pairing: pairing)
        defer { server.stop() }
        let events = Events()
        let link = RemotePeerConnection(origins: [origin], lastOrigin: nil, token: token,
                                        expectedServerId: "srv-elsewhere", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .identityMismatch(expected: "srv-elsewhere", actual: "srv-a") }
        try await waitUntil { events.states.filter { $0 == .connecting }.count >= 2 }
        // The second attempt just started (that's what the wait above proved);
        // give it a moment to run the same handshake and settle again.
        try await waitUntil { link.state == .identityMismatch(expected: "srv-elsewhere", actual: "srv-a") }
        #expect(!events.states.contains(.online))
        #expect(events.hellos.isEmpty)
    }

    // The core of the fix: a stale address reassigned to an unrelated Alas
    // instance must not stop the link from finding the real peer at a later
    // advertised origin. One shared pairing service so the SAME token is
    // valid at both origins — the fallback is proven by identity, not by one
    // server simply refusing an unrecognized token.
    @Test func aMismatchedOriginDoesNotStopTheRemainingOnesFromBeingTried() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let token = try pairing.redeem(code: pairing.beginPairing(), deviceName: "Mac B")
        let (wrongServer, wrongOrigin) = try await startServer(pairing: pairing, helloServerId: "srv-impostor")
        defer { wrongServer.stop() }
        let (rightServer, rightOrigin) = try await startServer(pairing: pairing, helloServerId: "srv-a")
        defer { rightServer.stop() }

        let events = Events()
        let link = RemotePeerConnection(origins: [wrongOrigin, rightOrigin], lastOrigin: nil, token: token,
                                        expectedServerId: "srv-a", config: fastConfig()) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .online }
        #expect(link.lastOrigin == rightOrigin)
        #expect(events.origins == [rightOrigin])
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
