import CryptoKit
import Foundation
import Testing
import AlasModel
@testable import AlasHostCore

/// Pairing a Mac with a headless host that cannot open a connection back to
/// it: macOS denies a launchd agent's outgoing LAN connections without a
/// prompt, so the host's pair-back can never land on a LAN-only Mac.
@MainActor
struct RemotePeerPairingTests {
    private typealias PeerStore = HostProtocolServerTests.MemoryPeerStore
    private typealias DeviceStore = HostProtocolServerTests.MemoryDeviceStore

    /// A headless host on loopback, wired as alas-host wires it.
    private struct Host {
        let pairing: RemotePairingService
        let key: RemoteIdentityKeyProvider
        let server: RemoteServer
        let peers: RemotePeerManager
        let origin: String
    }

    private func startHost(holding existing: [RemotePeer] = [], onPeerPaired: @escaping (RemotePeerPairingRequest) -> Void = { _ in })
        async throws -> Host {
        let pairing = RemotePairingService(store: DeviceStore(devices: []))
        let key = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        let server = RemoteServer(
            pairing: pairing, assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil, identity: { RemoteServerIdentity(serverId: "host", name: "Host") }, signer: key
        )
        let peers = RemotePeerManager(
            store: PeerStore(peers: existing), pairing: pairing,
            localIdentity: { .init(serverId: "host", name: "Host", origins: ["http://127.0.0.1:1"]) }
        )
        server.pairsBackWithPeers = false
        server.admitsInboundOnlyPeer = { peers.admitsInboundOnlyPeer($0) }
        server.onPeerPaired = { request in
            onPeerPaired(request)
            peers.notePeerPairingArrived(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
            Task { @MainActor in await peers.handleInboundPeer(request) }
        }
        try server.start(port: 0, loopbackOnly: true)
        try await eventually { await server.port != nil }
        return try Host(pairing: pairing, key: key, server: server, peers: peers,
                        origin: "http://127.0.0.1:\(#require(server.port))")
    }

    /// A Mac on the new version, advertising an origin nothing listens on, so
    /// a pair-back would fail and its short reciprocal wait would report it.
    private func makeMac(pairing: RemotePairingService) -> RemotePeerManager {
        let key = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        return RemotePeerManager(
            store: PeerStore(peers: []), pairing: pairing, reciprocalConfirmationTimeout: 2,
            localIdentity: {
                .init(serverId: "mac", name: "Mac", origins: ["http://127.0.0.1:1"], publicKey: key.publicKey)
            }
        )
    }

    /// Also a reinstalled Mac with a new key re-pairing: the host's earlier
    /// inbound-only record pinned no key, and keeps the token the app sharing
    /// its profile holds.
    @Test(arguments: [nil, "app-token"] as [String?])
    func aMacPairsWithAHeadlessHostThatCannotReachIt(existingToken: String?) async throws {
        var counterCode: String?
        let existing = existingToken.map {
            RemotePeer(id: "old", serverId: "mac", name: "Mac", origins: ["http://127.0.0.1:1"], token: $0, addedAt: .distantPast)
        }
        let host = try await startHost(holding: existing.map { [$0] } ?? []) { counterCode = $0.counterCode }
        defer { host.server.stop() }
        let macPairing = RemotePairingService(store: DeviceStore(devices: []))
        let mac = makeMac(pairing: macPairing)

        let error = await mac.addPeer(code: host.pairing.beginPairing(), origins: [host.origin])

        #expect(error == nil)
        let record = try #require(mac.peers.first)
        #expect(record.serverId == "host")
        #expect(record.publicKey == host.key.publicKey)
        #expect(record.localDeviceId == nil)
        // The counter-code the Mac offered can no longer authorize anyone.
        let offered = try #require(counterCode)
        #expect(throws: (any Error).self) {
            try macPairing.redeemPeer(code: offered, deviceName: "Host", peerServerId: "host")
        }
        try await eventually { await host.peers.peers.first?.localDeviceId != nil }
        let hostRecord = try #require(host.peers.peers.first)
        #expect(host.peers.peers.count == 1)
        #expect(hostRecord.publicKey == nil)
        #expect(hostRecord.token == existingToken ?? "")
        #expect(host.pairing.devices.map(\.id) == [hostRecord.localDeviceId])
        host.peers.forget(peerId: hostRecord.id)
        #expect(host.pairing.devices.isEmpty)
    }

    /// Refused before the reply, so the Mac hears it instead of keeping a
    /// token the host then revokes, and the code survives for a retry.
    @Test func aHeadlessHostRefusesAMacItHoldsUnderAnotherKey() async throws {
        let pinned = RemoteIdentityCrypto.publicKeyString(Curve25519.Signing.PrivateKey().publicKey)
        let host = try await startHost(holding: [RemotePeer(
            id: "old", serverId: "mac", name: "Mac", origins: ["http://127.0.0.1:1"], token: "t",
            publicKey: pinned, addedAt: .distantPast
        )])
        defer { host.server.stop() }
        let mac = makeMac(pairing: RemotePairingService(store: DeviceStore(devices: [])))
        let code = host.pairing.beginPairing()

        let error = await mac.addPeer(code: code, origins: [host.origin])

        #expect(error == .identityRebindRefused)
        #expect(mac.peers.isEmpty)
        #expect(host.pairing.devices.isEmpty)
        #expect(host.peers.peers.map(\.publicKey) == [pinned])
        #expect(throws: Never.self) { try host.pairing.redeemPeer(code: code, deviceName: "Mac", peerServerId: "mac") }
    }

    /// Only a host that does not pair back answers inbound-only, only to a
    /// Mac that asked for it, and only with a reply that proves its key.
    /// Everyone else gets today's exchange, pair-back included.
    @Test(arguments: [
        (pairsBack: false, accepts: true as Bool?, challenge: true, inboundOnly: true),
        (pairsBack: false, accepts: nil, challenge: true, inboundOnly: false),
        (pairsBack: true, accepts: true, challenge: true, inboundOnly: false),
        (pairsBack: false, accepts: true, challenge: false, inboundOnly: false),
    ])
    func aHostAnswersInboundOnlyOnlyWhenBothSidesCan(
        _ setup: (pairsBack: Bool, accepts: Bool?, challenge: Bool, inboundOnly: Bool)
    ) throws {
        let pairing = RemotePairingService(store: DeviceStore(devices: []))
        let key = Curve25519.Signing.PrivateKey()
        var requests: [RemotePeerPairingRequest] = []
        var responder = RemoteHTTPResponder(
            pairing: pairing, assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: {
                RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true, pairedDeviceCount: 0)
            },
            onPeerPaired: { requests.append($0) },
            identity: { RemoteServerIdentity(serverId: "host", name: "Host") },
            identityProof: { RemoteIdentityCrypto.sign(serverId: "host", challenge: $0, with: key) }
        )
        responder.pairsBackWithPeers = setup.pairsBack
        struct Body: Encodable {
            let code: String
            let deviceName: String
            let peer: RemotePeerAdvertisement
            let challenge: String?
        }
        let body = try JSONEncoder().encode(Body(
            code: pairing.beginPairing(), deviceName: "Mac",
            peer: RemotePeerAdvertisement(serverId: "mac", name: "Mac", origins: ["http://127.0.0.1:1"],
                                          counterCode: "COUNTER", acceptsInboundOnly: setup.accepts),
            challenge: setup.challenge ? RemoteIdentityCrypto.randomChallenge() : nil
        ))

        let out = responder.response(for: HTTPRequest(method: "POST", path: "/pair", query: [:], headers: [:]), body: body)

        let json = try #require(String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        let reply = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(reply["token"] is String)
        #expect(reply["inboundOnly"] as? Bool == (setup.inboundOnly ? true : nil))
        #expect(requests.map(\.inboundOnly) == [setup.inboundOnly])
    }

    /// An inbound-only reply skips the pair-back, which is what would
    /// otherwise vouch for the far side, so its key proof is all there is.
    @Test func aMacRefusesAnInboundOnlyReplyWithoutAProvenKey() async {
        let data = Data(#"{"token":"t","serverId":"host","inboundOnly":true}"#.utf8)
        let pairer = RemotePeerPairer(fetch: { request in
            (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let outcome = await pairer.pair(origins: ["http://127.0.0.1:1"], code: "C", deviceName: "Mac", advertisement: nil)

        #expect(outcome == .identityUnproven)
    }

    /// Absent stays absent on the wire, so an older host reads exactly what
    /// it always did.
    @Test(arguments: [nil, true] as [Bool?])
    func anAdvertisementRoundTripsItsInboundOnlyFlag(_ accepts: Bool?) throws {
        let advertisement = RemotePeerAdvertisement(
            serverId: "mac", name: "Mac", origins: [], counterCode: nil, acceptsInboundOnly: accepts
        )

        let data = try JSONEncoder().encode(advertisement)

        #expect(String(decoding: data, as: UTF8.self).contains("acceptsInboundOnly") == (accepts != nil))
        #expect(try JSONDecoder().decode(RemotePeerAdvertisement.self, from: data) == advertisement)
    }
}
