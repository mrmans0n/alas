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

    /// The Mac advertises an origin nothing listens on, so a pair-back
    /// would fail and the Mac's short reciprocal wait would report it.
    @Test func aMacPairsWithAHeadlessHostThatCannotReachIt() async throws {
        let hostPairing = RemotePairingService(store: DeviceStore(devices: []))
        let hostKey = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        let server = RemoteServer(
            pairing: hostPairing, assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            host: nil, identity: { RemoteServerIdentity(serverId: "host", name: "Host") }, signer: hostKey
        )
        server.pairsBackWithPeers = false
        let hostPeers = RemotePeerManager(
            store: PeerStore(peers: []), pairing: hostPairing,
            localIdentity: { .init(serverId: "host", name: "Host", origins: ["http://127.0.0.1:1"]) }
        )
        var counterCode: String?
        server.onPeerPaired = { request in
            counterCode = request.counterCode
            hostPeers.notePeerPairingArrived(serverId: request.peerServerId, localDeviceId: request.localDeviceId)
            Task { @MainActor in await hostPeers.handleInboundPeer(request) }
        }
        try server.start(port: 0, loopbackOnly: true)
        defer { server.stop() }
        try await eventually { await server.port != nil }
        let port = try #require(server.port)

        let macPairing = RemotePairingService(store: DeviceStore(devices: []))
        let macKey = RemoteIdentityKeyProvider(store: RemoteInMemorySecretStore())
        let mac = RemotePeerManager(
            store: PeerStore(peers: []), pairing: macPairing, reciprocalConfirmationTimeout: 2,
            localIdentity: {
                .init(serverId: "mac", name: "Mac", origins: ["http://127.0.0.1:1"], publicKey: macKey.publicKey)
            }
        )

        let error = await mac.addPeer(code: hostPairing.beginPairing(), origins: ["http://127.0.0.1:\(port)"])

        #expect(error == nil)
        let record = try #require(mac.peers.first)
        #expect(record.serverId == "host")
        #expect(record.publicKey == hostKey.publicKey)
        #expect(record.localDeviceId == nil)
        // The counter-code the Mac offered can no longer authorize anyone.
        let offered = try #require(counterCode)
        #expect(throws: (any Error).self) {
            try macPairing.redeemPeer(code: offered, deviceName: "Host", peerServerId: "host")
        }
        try await eventually { await hostPeers.peers.contains { $0.serverId == "mac" } }
        let hostRecord = try #require(hostPeers.peers.first)
        #expect(hostRecord.token.isEmpty)
        #expect(hostRecord.localDeviceId != nil)
        #expect(hostPairing.devices.map(\.id) == [hostRecord.localDeviceId])
        hostPeers.forget(peerId: hostRecord.id)
        #expect(hostPairing.devices.isEmpty)
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
    @Test(arguments: [
        #"{"token":"t","serverId":"host","inboundOnly":true}"#,
        #"{"token":"t","serverId":"host","inboundOnly":true,"publicKey":"KEY","signature":"bm90IGEgc2lnbmF0dXJl"}"#,
    ])
    func aMacRefusesAnInboundOnlyReplyWithoutAProvenKey(_ reply: String) async {
        let key = RemoteIdentityCrypto.publicKeyString(Curve25519.Signing.PrivateKey().publicKey)
        let data = Data(reply.replacingOccurrences(of: "KEY", with: key).utf8)
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
