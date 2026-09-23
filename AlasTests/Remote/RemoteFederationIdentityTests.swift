import Testing
import Foundation
import CryptoKit
@testable import Alas

/// End-to-end federation identity binding: two (and, for the attack, three)
/// in-process `RemoteServer`s talking over real loopback HTTP and WebSockets.
///
/// Unit-level signature checks cannot show what this issue is actually about.
/// The impersonation it closes is a whole exchange — a live pairing code
/// redeemed while advertising an established peer's `serverId`, which used to
/// re-key that peer's record and point this Mac's outbound link at the
/// claimant. Only a full round trip between real servers exercises the
/// pairing endpoint, the pair-back, the peer store and the link together.
@MainActor
struct RemoteFederationIdentityTests {
    private enum TimeoutError: Error { case timedOut }

    /// One simulated Mac: a server, its pairing registry, its identity key
    /// and its outbound peer manager, wired the way `AppState` wires them.
    @MainActor
    private final class Mac {
        let serverId: String
        let signer: RemoteIdentityKeyProvider
        let pairing: RemotePairingService
        let peerStore = InMemoryPeerStore()
        let server: RemoteServer
        private(set) var peers: RemotePeerManager!
        private(set) var port: UInt16 = 0

        var origin: String { "http://127.0.0.1:\(port)" }

        /// `pairing` can be shared with another Mac, which is how a test
        /// arranges for two servers to accept the SAME token — leaving the
        /// identity key as the only thing that tells them apart.
        init(serverId: String, name: String, key: RemoteIdentityKeyProvider? = nil,
             pairing: RemotePairingService? = nil) {
            self.serverId = serverId
            self.signer = key ?? RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
            self.pairing = pairing ?? RemotePairingService(store: InMemoryDeviceStore())
            let signer = self.signer
            self.server = RemoteServer(
                pairing: self.pairing,
                assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
                provider: FakeSessionsProvider(),
                identity: { RemoteServerIdentity(serverId: serverId, name: name, federationEnabled: true) },
                signer: signer)
        }

        func start(name: String) async throws {
            try server.start(port: 0)
            for _ in 0..<100 where server.port == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            port = try #require(server.port)
            let serverId = self.serverId
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
        }

        func stop() {
            peers?.disconnectAll()
            server.stop()
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, seconds: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Redeems `code` on `target` while advertising whatever identity the
    /// caller names — exactly what a code holder can do, since everything in
    /// the advertisement is self-reported.
    private func redeem(code: String, on target: Mac, claiming serverId: String, name: String,
                        publicKey: String?, origins: [String], counterCode: String?) async throws -> (Int, Data) {
        struct Body: Encodable {
            let code: String
            let deviceName: String
            let peer: RemotePeerAdvertisement
            let challenge: String
        }
        var request = URLRequest(url: URL(string: target.origin + "/pair")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = try JSONEncoder().encode(Body(
            code: code, deviceName: name,
            peer: RemotePeerAdvertisement(serverId: serverId, name: name, origins: origins,
                                          counterCode: counterCode, publicKey: publicKey),
            challenge: RemoteIdentityCrypto.randomChallenge()))
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// A completed, verified pairing between two real Macs.
    private func pairedMacs() async throws -> (a: Mac, b: Mac) {
        let a = Mac(serverId: "srv-a", name: "Mac A")
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await a.start(name: "Mac A")
        try await b.start(name: "Mac B")
        let code = a.pairing.beginPairing()
        let error = await b.peers.addPeer(code: code, origins: [a.origin])
        #expect(error == nil, "expected a clean pairing, got \(String(describing: error))")
        return (a, b)
    }

    @Test func pairingTwoRealMacsPinsEachSideToTheOthersProvenKey() async throws {
        let (a, b) = try await pairedMacs()
        defer { a.stop()
        b.stop() }

        let bRecordOfA = try #require(b.peers.peers.first { $0.serverId == "srv-a" })
        #expect(bRecordOfA.publicKey == a.signer.publicKey)
        #expect(bRecordOfA.isVerified)

        // The pair-back means A holds a pinned record for B too. B's own
        // `addPeer` returns the moment A's reciprocal call lands on B, which
        // is just BEFORE A finishes writing its own row — so wait for it
        // rather than racing A's last step.
        try await waitUntil { a.peers.peers.contains { $0.serverId == "srv-b" } }
        let aRecordOfB = try #require(a.peers.peers.first { $0.serverId == "srv-b" })
        #expect(aRecordOfB.publicKey == b.signer.publicKey)
        #expect(aRecordOfB.isVerified)
    }

    // The acceptance case. A claimant holding one live pairing code redeems
    // it on B while advertising A's `serverId` — the exact move that used to
    // replace A's token and origin in B's store and send B's outbound link
    // to the claimant instead.
    @Test func redeemingACodeWhileClaimingAnExistingPeersIdentityCannotRekeyThatRecord() async throws {
        let (a, b) = try await pairedMacs()
        // The claimant is a third real Alas instance that reports A's
        // identity in everything it says, and holds a key of its own.
        let claimant = Mac(serverId: "srv-a", name: "Impostor")
        try await claimant.start(name: "Impostor")
        defer { a.stop()
        b.stop()
        claimant.stop() }

        let before = try #require(b.peers.peers.first { $0.serverId == "srv-a" })
        let devicesBefore = b.pairing.devices.count

        // The user displays a fresh code on B; the claimant redeems it.
        let code = b.pairing.beginPairing()
        let (status, _) = try await redeem(code: code, on: b, claiming: "srv-a", name: "Impostor",
                                           publicKey: claimant.signer.publicKey,
                                           origins: [claimant.origin],
                                           counterCode: claimant.pairing.beginPairing())
        // The redeem itself can succeed — holding the code is all that
        // proves — but what follows must leave nothing behind.
        #expect(status == 200 || status == 403)

        // Give the inbound handler (and any pair-back it might attempt) a
        // real chance to run before asserting nothing changed.
        try await Task.sleep(nanoseconds: 500_000_000)

        let after = try #require(b.peers.peers.first { $0.serverId == "srv-a" })
        #expect(after.id == before.id)
        #expect(after.token == before.token)
        #expect(after.publicKey == a.signer.publicKey)
        #expect(after.origins == before.origins)
        #expect(after.lastOrigin == before.lastOrigin)
        #expect(!after.origins.contains(claimant.origin))
        #expect(b.peers.peers.count == 1, "no second record for the claimed identity either")

        // And the claimant is left with no inbound access on B: the device
        // its redeem minted was taken back.
        #expect(b.pairing.devices.count == devicesBefore)
        #expect(!b.pairing.devices.contains { $0.name == "Impostor" })
    }

    // The other half of the same attack: even if a record's address ends up
    // pointing at the claimant, the socket that carries traffic has to prove
    // possession of the pinned key. Here B's record for A is re-pointed at
    // the claimant by hand — a stronger position than the pairing path can
    // actually reach — and the link must still refuse it.
    @Test func anOutboundLinkRefusesAMacThatCannotProveThePinnedKey() async throws {
        let (a, b) = try await pairedMacs()
        // The claimant reports A's identity AND, by sharing A's device
        // registry, accepts the very token B holds for A. Everything the old
        // code checked therefore passes; only possession of A's key does not.
        let claimant = Mac(serverId: "srv-a", name: "Impostor", pairing: a.pairing)
        try await claimant.start(name: "Impostor")
        defer { a.stop()
        b.stop()
        claimant.stop() }

        let record = try #require(b.peers.peers.first { $0.serverId == "srv-a" })
        let events = RemotePeerConnectionEvents()
        var config = RemotePeerConnection.Config()
        config.handshakeTimeout = 2
        config.initialBackoff = 0.2
        config.maxBackoff = 0.5
        let link = RemotePeerConnection(
            origins: [claimant.origin], lastOrigin: nil, token: record.token,
            expectedServerId: "srv-a", expectedPublicKey: record.publicKey,
            config: config) { events.all.append($0) }
        link.connect()
        defer { link.disconnect() }
        try await waitUntil { link.state == .identityUnproven }
        #expect(!events.states.contains(.online))

        // The real A, over the same pinned record, still comes online.
        let good = RemotePeerConnection(
            origins: [a.origin], lastOrigin: nil, token: record.token,
            expectedServerId: "srv-a", expectedPublicKey: record.publicKey,
            config: config) { _ in }
        good.connect()
        defer { good.disconnect() }
        try await waitUntil { good.state == .online }
    }

    // Pairing with a Mac that has no identity key at all (an older build)
    // still works — breaking every existing pairing on upgrade would be
    // worse than the gap — but the record it produces is unverified, and
    // session aggregation refuses to carry anything over it.
    @Test func pairingWithAMacThatOffersNoKeyLeavesAnUnverifiedRecord() async throws {
        // A key provider with no durable storage advertises nothing.
        let old = Mac(serverId: "srv-old", name: "Old Mac",
                      key: RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore(writable: false)))
        let b = Mac(serverId: "srv-b", name: "Mac B")
        try await old.start(name: "Old Mac")
        try await b.start(name: "Mac B")
        defer { old.stop()
        b.stop() }

        #expect(await b.peers.addPeer(code: old.pairing.beginPairing(), origins: [old.origin]) == nil)
        let record = try #require(b.peers.peers.first { $0.serverId == "srv-old" })
        #expect(record.publicKey == nil)
        #expect(!record.isVerified)
        #expect(!b.peers.carriesSessions(peerId: record.id))
    }
}

/// Event sink for the links these tests drive directly.
@MainActor
final class RemotePeerConnectionEvents {
    var all: [RemotePeerConnection.Event] = []
    var states: [RemotePeerConnection.State] {
        all.compactMap { if case .stateChanged(let s) = $0 { return s } else { return nil } }
    }
}
