import Testing
import Foundation
@testable import Alas

/// Gateway aggregation over real loopback servers: a phone paired with A sees
/// and drives B's sessions through A, and nothing echoes around a chain.
///
/// Every Mac here is a real in-process `RemoteServer` on its own OS-assigned
/// port, paired through the real `/pair` endpoint, linked by real
/// `RemotePeerManager` sockets and driven by a real WebSocket client. The
/// unit suites cover the router in isolation; only this one shows that the
/// namespacing, the `carriesSessions` gate, the gateway's merged list and the
/// peer links actually compose into a working gateway.
@MainActor
struct RemoteFederationAggregationTests {
    private enum TimeoutError: Error { case timedOut }

    /// One simulated Mac, wired the way `AppState` wires them — with its
    /// `FakeSessionsProvider` kept so a test can plant sessions on it, and a
    /// `FederatedSessionsProvider` attached to the server once `peers` exists.
    @MainActor
    private final class Mac {
        let serverId: String
        let name: String
        let signer: RemoteIdentityKeyProvider
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let peerStore = InMemoryPeerStore()
        let provider = FakeSessionsProvider()
        let server: RemoteServer
        private(set) var peers: RemotePeerManager!
        private(set) var federation: FederatedSessionsProvider!
        private(set) var port: UInt16 = 0

        var origin: String { "http://127.0.0.1:\(port)" }

        init(serverId: String, name: String, key: RemoteIdentityKeyProvider? = nil) {
            self.serverId = serverId
            self.name = name
            self.signer = key ?? RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
            let signer = self.signer
            self.server = RemoteServer(
                pairing: pairing,
                assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
                provider: provider,
                identity: {
                    RemoteServerIdentity(serverId: serverId, name: name, hubEnabled: false,
                                         federationEnabled: true)
                },
                signer: signer)
        }

        func start() async throws {
            try server.start(port: 0)
            for _ in 0..<100 where server.port == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            port = try #require(server.port)
            let serverId = self.serverId
            let name = self.name
            let signer = self.signer
            // Captured after the port is known, so the advertisement always
            // names the address this Mac actually answers on.
            let originBox = { [weak self] in self?.origin ?? "" }
            peers = RemotePeerManager(
                store: peerStore,
                pairing: pairing,
                pairer: .live,
                reciprocalConfirmationTimeout: 15,
                localIdentity: {
                    RemotePeerManager.LocalIdentity(serverId: serverId, name: name,
                                                    origins: [originBox()],
                                                    publicKey: signer.publicKey)
                })
            peers.onRevokeDevice = { [weak self] deviceId in self?.server.disconnectDevice(deviceId) }
            server.onPeerPaired = { [weak self] request in
                guard let self else { return }
                self.peers.notePeerPairingArrived(serverId: request.peerServerId,
                                                  localDeviceId: request.localDeviceId)
                Task { @MainActor in await self.peers.handleInboundPeer(request) }
            }
            federation = FederatedSessionsProvider(links: peers)
            server.federation = federation
            peers.connectAll()
        }

        func stop() {
            peers?.disconnectAll()
            server.stop()
        }

        /// Drops every federation socket this Mac has — the links it dialled
        /// and the ones its peers dialled into it — which is what the far
        /// side sees when this Mac shuts down or turns peers off.
        ///
        /// Not `stop()`: that also drops the server's connection table in the
        /// same turn it asks each connection to cancel, and the cancel only
        /// reaches the socket on a later queue hop — so the released
        /// connection can be gone before its FIN ever goes out, leaving the
        /// far side holding a socket nobody will ever close.
        func dropFederationLinks() {
            peers.disconnectAll()
            server.disconnectAllPeerDevices()
        }

        /// Plants a live session on this Mac and returns its id.
        func plantSession(text: String, manager: ACPSessionManager) -> String {
            let session = manager.createSession(agentId: "claude")
            session.transcript.messages = [.agent(id: UUID(), StreamingText(text))]
            provider.sessions[session.id] = session
            provider.writers.insert(session.id)
            provider.summaries.append(
                RemoteSessionSummary(id: session.id, title: "On \(name)", agentId: "claude",
                                     status: "idle", canDrive: true))
            return session.id
        }
    }

    /// A paired browser client of `mac`: redeems a code over HTTP, opens the
    /// socket, and swallows the leading `hello`.
    @MainActor
    private final class Phone {
        let task: URLSessionWebSocketTask

        init(of mac: Mac) async throws {
            let code = mac.pairing.beginPairing()
            var request = URLRequest(url: URL(string: mac.origin + "/pair")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            struct PairResp: Decodable { let token: String }
            let token = try JSONDecoder().decode(PairResp.self, from: data).token
            task = URLSession.shared.webSocketTask(
                with: URL(string: "ws://127.0.0.1:\(mac.port)/ws")!, protocols: [token])
            task.resume()
            _ = try await receive()
        }

        func send(_ message: RemoteClientMessage) async throws {
            try await task.send(.data(JSONEncoder().encode(message)))
        }

        /// One frame, or `TimeoutError` if none arrives in time.
        ///
        /// `URLSessionWebSocketTask.receive()` never observes task
        /// cancellation and waits forever, so an un-deadlined read of a frame
        /// the server never sends would hang the whole suite instead of
        /// failing this test. Cancelling the socket is what ends that wait —
        /// the caller is throwing anyway.
        func receive(timeout: TimeInterval = 20) async throws -> RemoteServerMessage {
            let socket = task
            let raw = await withTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
                group.addTask { try? await socket.receive() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                if first == nil { socket.cancel(with: .goingAway, reason: nil) }
                group.cancelAll()
                return first
            }
            let payload: Data
            switch raw {
            case .data(let d): payload = d
            case .string(let s): payload = Data(s.utf8)
            case .none: throw TimeoutError.timedOut
            @unknown default: throw TimeoutError.timedOut
            }
            return try JSONDecoder().decode(RemoteServerMessage.self, from: payload)
        }

        /// Reads frames until `matches` returns a value, or `limit` frames pass.
        /// A federated client legitimately sees several list refreshes, config
        /// and queue frames before the one it is waiting for.
        func receive<T>(limit: Int = 40, _ matches: (RemoteServerMessage) -> T?) async throws -> T {
            for _ in 0..<limit {
                if let value = matches(try await receive()) { return value }
            }
            throw TimeoutError.timedOut
        }

        func close() { task.cancel(with: .goingAway, reason: nil) }
    }

    private func makeManager() throws -> ACPSessionManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-fed-\(UUID()).sqlite")
        return ACPSessionManager(worktreeId: "wt", worktreePath: "/tmp", store: try ACPSessionStore(path: url.path))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// `a` pairs with `b`; returns once both links carry sessions.
    ///
    /// `sessionCarryingPeers` flipping is also the moment each side's
    /// `FederatedSessionsProvider` has reconciled — the manager updates
    /// `states` before it fires `availabilityChanged`, and the provider
    /// handles that event synchronously — so callers may route peer ids as
    /// soon as this returns.
    private func pair(_ a: Mac, _ b: Mac) async throws {
        let code = b.pairing.beginPairing()
        let error = await a.peers.addPeer(code: code, origins: [b.origin])
        #expect(error == nil, "expected a clean pairing, got \(String(describing: error))")
        try await waitUntil {
            a.peers.sessionCarryingPeers.contains { $0.serverId == b.serverId }
                && b.peers.sessionCarryingPeers.contains { $0.serverId == a.serverId }
        }
    }

    @Test func aPhoneOnASeesAndStreamsBsSessionThroughA() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start()
        try await b.start()
        defer {
            a.stop()
            b.stop()
        }
        let manager = try makeManager()
        let bSession = b.plantSession(text: "hello-from-b", manager: manager)
        try await pair(a, b)
        try await waitUntil { a.federation.peerSessionSummaries.contains { $0.id == "srv-b:\(bSession)" } }

        let phone = try await Phone(of: a)
        defer { phone.close() }
        try await phone.send(.listSessions)
        let rows = try await phone.receive { message -> [RemoteSessionSummary]? in
            if case .sessionList(let rows) = message { return rows }
            return nil
        }
        let row = try #require(rows.first { $0.id == "srv-b:\(bSession)" })
        #expect(row.serverId == "srv-b")
        #expect(row.serverName == "Mac B")
        #expect(row.title == "On Mac B")

        try await phone.send(.subscribe(sessionId: "srv-b:\(bSession)"))
        let snapshot = try await phone.receive { message -> [RemoteWireMessage]? in
            if case .transcriptSnapshot("srv-b:\(bSession)", _, _, let messages, _, _, _, _) = message { return messages }
            return nil
        }
        #expect(snapshot.contains { $0.text == "hello-from-b" })
    }

    @Test func driveVerbsLandOnTheHomeMacAndRefusalsComeBack() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start()
        try await b.start()
        defer {
            a.stop()
            b.stop()
        }
        let manager = try makeManager()
        let bSession = b.plantSession(text: "x", manager: manager)
        try await pair(a, b)
        let phone = try await Phone(of: a)
        defer { phone.close() }
        try await phone.send(.subscribe(sessionId: "srv-b:\(bSession)"))
        _ = try await phone.receive { message -> Bool? in
            if case .transcriptSnapshot("srv-b:\(bSession)", _, _, _, _, _, _, _) = message { return true }
            return nil
        }

        try await phone.send(.sendPrompt(sessionId: "srv-b:\(bSession)", text: "do it", attachments: [], intent: "auto"))
        try await waitUntil { b.provider.prompts.contains { $0.id == bSession && $0.text == "do it" } }
        #expect(a.provider.prompts.isEmpty)

        try await phone.send(.renameSession(sessionId: "srv-b:\(bSession)", title: "Renamed"))
        try await waitUntil { b.provider.renamed.contains { $0.id == bSession && $0.title == "Renamed" } }
        let renamed = try await phone.receive { message -> String? in
            if case .sessionRenamed("srv-b:\(bSession)", let title) = message { return title }
            return nil
        }
        #expect(renamed == "Renamed")

        // B decides who may drive. Take the lease away and the forwarded
        // prompt is refused by B, and the refusal reaches the phone.
        b.provider.writers.remove(bSession)
        try await phone.send(.sendPrompt(sessionId: "srv-b:\(bSession)", text: "again", attachments: [], intent: "auto"))
        let rejected = try await phone.receive { message -> Bool? in
            if case .promptRejected("srv-b:\(bSession)") = message { return true }
            return nil
        }
        #expect(rejected)
        #expect(!b.provider.prompts.contains { $0.text == "again" })
    }

    @Test func aChainDoesNotEchoSessionsPastOneHop() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        let c = Mac(serverId: "srv-c", name: "Mac C")
        try await a.start()
        try await b.start()
        try await c.start()
        defer {
            a.stop()
            b.stop()
            c.stop()
        }
        let manager = try makeManager()
        let aSession = a.plantSession(text: "a", manager: manager)
        let cSession = c.plantSession(text: "c", manager: manager)
        try await pair(a, b)
        try await pair(b, c)
        // B sees both neighbours.
        try await waitUntil {
            b.federation.peerSessionSummaries.map(\.id).sorted()
                == ["srv-a:\(aSession)", "srv-c:\(cSession)"].sorted()
        }
        // B's list now carries C's row (and A's), and B's gateways push it to
        // both neighbours unprompted. Give that push time to land, then check
        // A never adopted C's row, and that A's own row did not come back to A
        // — or reach C — through B.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(a.federation.peerSessionSummaries.isEmpty)
        #expect(!c.federation.peerSessionSummaries.contains { $0.id.hasPrefix("srv-b:srv-a:") })
        #expect(c.federation.peerSessionSummaries.isEmpty)
    }

    @Test func aPeerGoingAwayClosesItsSessionsForThePhone() async throws {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start()
        try await b.start()
        defer {
            a.stop()
            b.stop()
        }
        let manager = try makeManager()
        let bSession = b.plantSession(text: "x", manager: manager)
        try await pair(a, b)
        let phone = try await Phone(of: a)
        defer { phone.close() }
        try await phone.send(.subscribe(sessionId: "srv-b:\(bSession)"))
        _ = try await phone.receive { message -> Bool? in
            if case .transcriptSnapshot("srv-b:\(bSession)", _, _, _, _, _, _, _) = message { return true }
            return nil
        }

        // B goes away. Its live federation sockets are closed first, and its
        // listener only once A has actually seen the link go down: a link
        // whose socket closed while the far side is still listening simply
        // redials it after its backoff, and B would be back before the
        // assertions below ever ran.
        b.dropFederationLinks()
        try await waitUntil { a.peers.sessionCarryingPeers.isEmpty }
        b.stop()

        let closed = try await phone.receive { message -> Bool? in
            if case .sessionClosed("srv-b:\(bSession)") = message { return true }
            return nil
        }
        #expect(closed)
        try await waitUntil { a.federation.peerSessionSummaries.isEmpty }
        try await phone.send(.listSessions)
        let rows = try await phone.receive { message -> [RemoteSessionSummary]? in
            if case .sessionList(let rows) = message { return rows }
            return nil
        }
        #expect(!rows.contains { $0.serverId == "srv-b" })
    }

    @Test func anUnverifiedPeerNeverCarriesSessions() async throws {
        // A Mac with no identity key pairs but is never pinned; its record
        // on A stays unverified, so A must not surface its sessions even
        // though the link itself is online.
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let keyless = Mac(serverId: "srv-k", name: "Keyless",
                          key: RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore(writable: false)))
        try await a.start()
        try await keyless.start()
        defer {
            a.stop()
            keyless.stop()
        }
        let manager = try makeManager()
        _ = keyless.plantSession(text: "secret", manager: manager)
        let code = keyless.pairing.beginPairing()
        _ = await a.peers.addPeer(code: code, origins: [keyless.origin])
        try await waitUntil { a.peers.states.values.contains(.online) }
        let record = try #require(a.peers.peers.first { $0.serverId == "srv-k" })
        #expect(!record.isVerified)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(a.peers.sessionCarryingPeers.isEmpty)
        #expect(a.federation.peerSessionSummaries.isEmpty)
    }
}
