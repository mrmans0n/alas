import Testing
import Foundation
@testable import Alas

@MainActor
struct RemotePeerManagerTests {
    @MainActor
    final class FakeLink: RemotePeerConnecting {
        var state: RemotePeerConnection.State = .idle
        var connectCalls = 0
        var disconnectCalls = 0
        let emit: @MainActor (RemotePeerConnection.Event) -> Void
        init(emit: @escaping @MainActor (RemotePeerConnection.Event) -> Void) { self.emit = emit }
        func connect() { connectCalls += 1 }
        func disconnect() { disconnectCalls += 1 }
        func send(_ message: RemoteClientMessage) {}
    }

    final class Links {
        var byPeerId: [String: FakeLink] = [:]
    }

    final class Requests {
        var seen: [URLRequest] = []
    }

    private let identity = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "Mac B", origins: ["http://10.0.0.2:8765"])
    private let linkFromA = "http://10.0.0.1:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.1%3A8765"

    private func pairer(_ script: [String: (Int, String)], requests: Requests) -> RemotePeerPairer {
        RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            let key = "\(req.url!.host!):\(req.url!.port!)"
            guard let (status, body) = script[key] else { throw URLError(.cannotConnectToHost) }
            return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
    }

    private func makeManager(store: InMemoryPeerStore = InMemoryPeerStore(),
                             pairing: RemotePairingService = RemotePairingService(store: InMemoryDeviceStore()),
                             pairer: RemotePeerPairer, links: Links,
                             identity: RemotePeerManager.LocalIdentity? = nil) -> RemotePeerManager {
        let identity = identity ?? self.identity
        return RemotePeerManager(
            store: store, pairing: pairing, pairer: pairer,
            localIdentity: { identity },
            makeConnection: { peer, onEvent in
                let link = FakeLink(emit: onEvent)
                links.byPeerId[peer.id] = link
                return link
            },
            now: { Date(timeIntervalSince1970: 1000) })
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        // Two statements, not one: a `#require` nested inside another
        // `#require` is rejected as a recursive macro expansion.
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func invalidLinkIsRejectedWithoutNetwork() async {
        let requests = Requests()
        let manager = makeManager(pairer: pairer([:], requests: requests), links: Links())
        #expect(await manager.addPeer(link: "nope") == .invalidLink)
        #expect(requests.seen.isEmpty)
        #expect(manager.peers.isEmpty)
    }

    @Test func addPeerPairsStoresAndAdvertisesACounterCode() async throws {
        let requests = Requests()
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let store = InMemoryPeerStore()
        let links = Links()
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: links)
        manager.connectAll()
        #expect(await manager.addPeer(link: linkFromA) == nil)
        let peer = try #require(manager.peers.first)
        #expect(peer.serverId == "srv-a")
        #expect(peer.name == "Mac A")
        #expect(peer.token == "tokA")
        #expect(peer.origins == ["http://10.0.0.1:8765"])
        #expect(peer.lastOrigin == "http://10.0.0.1:8765")
        #expect(store.saved == manager.peers)
        #expect(links.byPeerId[peer.id]?.connectCalls == 1)

        let sent = try body(of: try #require(requests.seen.first))
        let ad = try #require(sent["peer"] as? [String: Any])
        #expect(ad["serverId"] as? String == "srv-b")
        #expect(ad["origins"] as? [String] == ["http://10.0.0.2:8765"])
        let counterCode = try #require(ad["counterCode"] as? String)
        // The counter-code is a real code on this Mac: A can redeem it.
        #expect((try? pairing.redeem(code: counterCode, deviceName: "Mac A")) != nil)
    }

    @Test func addPeerSurfacesPairerOutcomes() async {
        let expired = makeManager(pairer: pairer(["10.0.0.1:8765": (401, "{}")], requests: Requests()), links: Links())
        #expect(await expired.addPeer(link: linkFromA) == .expiredCode)
        let forbidden = makeManager(pairer: pairer(["10.0.0.1:8765": (403, "{}")], requests: Requests()), links: Links())
        #expect(await forbidden.addPeer(link: linkFromA) == .originRejected)
        let dead = makeManager(pairer: pairer([:], requests: Requests()), links: Links())
        #expect(await dead.addPeer(link: linkFromA) == .unreachable)
    }

    // With nothing to advertise, the far side's pair-back has nothing to dial
    // and revokes the device it just minted. Reporting success and then
    // "revoked" blames the other Mac for a local misconfiguration, so the add
    // is refused up front — before a counter-code is even minted.
    @Test func addPeerWithNoAdvertisableAddressIsRefusedBeforeAnyNetworkCall() async {
        let requests = Requests()
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let manager = makeManager(
            pairing: pairing,
            pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
            links: Links(),
            identity: RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "Mac B", origins: []))
        #expect(await manager.addPeer(link: linkFromA) == .noLocalAddress)
        #expect(requests.seen.isEmpty)
        #expect(manager.peers.isEmpty)
        #expect(pairing.devices.isEmpty)
    }

    @Test func inboundPeerWithCounterCodePairsBackWithoutNesting() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC", localDeviceId: "dev-a"))
        let peer = try #require(manager.peers.first)
        #expect(peer.serverId == "srv-a")
        #expect(peer.token == "tokA")
        #expect(peer.localDeviceId == "dev-a")
        let sent = try body(of: try #require(requests.seen.first))
        #expect(sent["code"] as? String == "CC")
        let ad = try #require(sent["peer"] as? [String: Any])
        #expect(ad["counterCode"] == nil)
    }

    @Test func inboundPeerWithoutCounterCodeLinksTheDeviceRecord() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        _ = await manager.addPeer(link: linkFromA)
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil, localDeviceId: "dev-a"))
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
        #expect(requests.seen.count == 1)
    }

    @Test func forgetRevokesTheInboundDeviceAndDisconnects() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        var revoked: [String] = []
        let links = Links()
        let manager = makeManager(pairing: pairing,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: links)
        manager.onRevokeDevice = { revoked.append($0) }
        manager.connectAll()
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC", localDeviceId: inbound.deviceId))
        let peer = try #require(manager.peers.first)
        manager.forget(peerId: peer.id)
        #expect(manager.peers.isEmpty)
        #expect(manager.states[peer.id] == nil)
        #expect(links.byPeerId[peer.id]?.disconnectCalls == 1)
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    @Test func rePairingAnExistingPeerReplacesTheTokenMergesOriginsAndSwapsTheLink() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let links = Links()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: links)
        manager.connectAll()
        let oldLink = try #require(links.byPeerId["p1"])
        #expect(await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765") == nil)
        #expect(manager.peers.count == 1)
        let peer = try #require(manager.peers.first)
        #expect(peer.id == "p1")
        #expect(peer.token == "tokA")
        #expect(peer.name == "Mac A")
        #expect(peer.origins == ["http://10.0.0.1:8765", "http://10.0.0.9:8765"])
        #expect(peer.lastOrigin == "http://10.0.0.9:8765")
        #expect(peer.localDeviceId == "dev-a")
        #expect(store.saved == manager.peers)
        // The stale link must be torn down, not left running alongside a
        // second one dialing the same peer with the new token.
        #expect(oldLink.disconnectCalls == 1)
        let newLink = try #require(links.byPeerId["p1"])
        #expect(newLink !== oldLink)
        #expect(newLink.connectCalls == 1)
    }

    @Test func forgetRevokesByPeerServerIdWhenNoLocalDeviceIdWasRecorded() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        var revoked: [String] = []
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer([:], requests: Requests()), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        manager.forget(peerId: "p1")
        #expect(manager.peers.isEmpty)
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    @Test func linkEventsUpdateStateNameVersionAndOrigin() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765", "http://10.0.0.5:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        let link = try #require(links.byPeerId["p1"])
        link.emit(.stateChanged(.online))
        link.emit(.hello(serverId: "srv-a", name: "Mac A", protocolVersion: 1, federationEnabled: true))
        link.emit(.originChanged("http://10.0.0.5:8765"))
        #expect(manager.states["p1"] == .online)
        #expect(manager.peers.first?.name == "Mac A")
        #expect(manager.peers.first?.protocolVersion == 1)
        #expect(manager.peers.first?.lastOrigin == "http://10.0.0.5:8765")
        #expect(store.saved.first?.lastOrigin == "http://10.0.0.5:8765")
    }

    // A `hello` is whatever answered the origin. Adopting its identity would
    // let a reassigned address or a squatter re-key the record, and because
    // `forget` revokes devices by identity the user would then revoke the
    // wrong peer's access while the impostor kept its own.
    @Test func helloNeverRewritesTheStoredServerId() throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        let link = try #require(links.byPeerId["p1"])
        link.emit(.hello(serverId: "srv-impostor", name: "Mac A", protocolVersion: 1, federationEnabled: true))
        #expect(manager.peers.first?.serverId == "srv-a")
        #expect(store.saved.first?.serverId == "srv-a")
        // The cosmetic fields are still adopted.
        #expect(manager.peers.first?.name == "Mac A")
        #expect(manager.peers.first?.protocolVersion == 1)
    }

    @Test func connectAllIsIdempotentAndDisconnectAllTearsDown() {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "A", origins: ["http://10.0.0.1:8765"], lastOrigin: nil,
                               token: "t", protocolVersion: nil, localDeviceId: nil, addedAt: Date())])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        manager.connectAll()
        #expect(links.byPeerId["p1"]?.connectCalls == 1)
        manager.disconnectAll()
        #expect(links.byPeerId["p1"]?.disconnectCalls == 1)
        #expect(manager.states.isEmpty)
    }
}
