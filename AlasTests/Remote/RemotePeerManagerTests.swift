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
                             identity: RemotePeerManager.LocalIdentity? = nil,
                             // Short but non-zero real time: long enough that a
                             // sleeping poll loop would visibly slow the suite
                             // down if a link's resolution were ever missed,
                             // short enough that the "no answer yet" timeout
                             // path in every OTHER test costs only ~20ms.
                             reciprocalConfirmationTimeout: TimeInterval = 0.05) -> RemotePeerManager {
        let identity = identity ?? self.identity
        return RemotePeerManager(
            store: store, pairing: pairing, pairer: pairer,
            reciprocalConfirmationTimeout: reciprocalConfirmationTimeout,
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

    /// Simulates A's reciprocal call landing WHILE `addPeer`'s confirmation
    /// wait is still polling — the real-world timing this represents. A tiny
    /// real delay lets `addPeer` start waiting first; well under any test's
    /// confirmation timeout, so it always lands inside the window.
    @discardableResult
    private func confirmReciprocalPairing(on manager: RemotePeerManager, peerServerId: String,
                                          peerName: String = "Mac A",
                                          origins: [String] = ["http://10.0.0.1:8765"],
                                          localDeviceId: String = "dev-a") -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await manager.handleInboundPeer(RemotePeerPairingRequest(
                peerServerId: peerServerId, peerName: peerName, origins: origins,
                counterCode: nil, localDeviceId: localDeviceId))
        }
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
        // Simulates A actually redeeming our counter-code, which is what
        // `addPeer` now waits to confirm before reporting success.
        confirmReciprocalPairing(on: manager, peerServerId: "srv-a")
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

    // The core of the Codex fix: A's own /pair reply succeeding only proves
    // OUR call to A worked, not that A's reciprocal pair-back to US did — our
    // own outbound link would come online just fine either way, since its
    // token is already valid regardless of A's leg of the exchange. If A
    // cannot reach any of our origins, A's reciprocal call to us never
    // arrives, and A's failure produces no error message routed back to us —
    // only silence. `addPeer` must wait for the ONE signal that actually
    // proves the exchange completed (A's call landing on our own /pair and
    // setting `localDeviceId`), and report failure if it never does, rather
    // than assume success just because the first leg answered.
    @Test func addPeerReportsFailureAndForgetsThePeerWhenNoConfirmationArrives() async {
        let requests = Requests()
        let store = InMemoryPeerStore()
        let links = Links()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: links)
        manager.connectAll()
        // Nothing ever calls handleInboundPeer for "srv-a": A's reciprocal
        // call never lands, exactly as if A could not reach us.
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        // Forgotten, not left half-paired: no dangling record whose token A
        // may since have revoked.
        #expect(manager.peers.isEmpty)
        #expect(store.saved.isEmpty)
        #expect(links.byPeerId.values.first?.disconnectCalls == 1)
    }

    // The happy path resolves fast rather than by exhausting the wait
    // window — proven by timing, since the return value alone (`nil`) is
    // identical whether confirmation genuinely landed or the wait just
    // timed out with nothing better to report. (Timing out now means
    // failure, not success — see the test above.)
    @Test func addPeerResolvesQuicklyOnceReciprocalConfirmationArrives() async {
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: Links())
        manager.connectAll()
        confirmReciprocalPairing(on: manager, peerServerId: "srv-a")
        let start = Date()
        #expect(await manager.addPeer(link: linkFromA) == nil)
        // The manager's own timeout for this suite is 0.05s; the confirming
        // task's own delay is 5ms — resolving well under the timeout shows
        // the wait picked up the confirmation rather than idling out.
        #expect(Date().timeIntervalSince(start) < 0.03)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
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

    // A's reciprocal call (counterCode: nil, since it is the responder that
    // already has ITS OWN advertisement's counterCode set to nil) lands WHILE
    // `addPeer` is still waiting to confirm the exchange — this is what lets
    // `addPeer` return success at all, and is the same signal it depends on.
    @Test func inboundPeerWithoutCounterCodeLinksTheDeviceRecord() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        confirmReciprocalPairing(on: manager, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
        #expect(requests.seen.count == 1)
    }

    // Codex: A schedules its reciprocal call right after redeeming our code,
    // before A's own HTTP reply to OUR original request has even finished
    // transmitting — so A's reciprocal call can land on our /pair endpoint
    // and reach `handleInboundPeer` before our own `addPeer` has returned
    // from the network call that creates this record. Without buffering,
    // the "else" branch's lookup finds nothing and the ONLY confirmation
    // this attempt will ever get is silently dropped.
    @Test func aReciprocalConfirmationThatArrivesBeforeTheRecordExistsIsNotLost() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        // Arrives immediately, synchronously — before `addPeer` has even
        // started, let alone created a record for "srv-a".
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil, localDeviceId: "dev-a"))
        #expect(manager.peers.isEmpty)   // buffered, not a dangling record
        #expect(await manager.addPeer(link: linkFromA) == nil)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
    }

    // Codex: an unmatched confirmation buffered by an EARLIER, unrelated
    // attempt (one whose own addPeer never reached upsert) must not sit
    // around forever and then wrongly satisfy a LATER, different attempt's
    // wait for the same peer.
    @Test func aStaleBufferedConfirmationFromAnEarlierAttemptDoesNotSatisfyALaterOne() async {
        let manager = makeManager(
            pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
            links: Links(), reciprocalConfirmationTimeout: 0.02)
        // Simulates A's reciprocal call landing for a PRIOR attempt that
        // never got as far as creating a record (e.g. our own outbound leg
        // to A failed after this had already arrived), then going stale
        // before any add for "srv-a" actually happens.
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil, localDeviceId: "stale-dev"))
        try? await Task.sleep(nanoseconds: 40_000_000)   // outlast the 0.02s window
        // Nothing confirms THIS attempt — the stale buffered entry must not
        // stand in for it.
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        #expect(manager.peers.isEmpty)
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
        // A fresh confirmation for THIS attempt — the record's OLD
        // localDeviceId ("dev-a" from the seeded store) must not be enough
        // on its own; see rePairingResetsStaleReciprocalConfirmation below.
        confirmReciprocalPairing(on: manager, peerServerId: "srv-a", localDeviceId: "dev-a")
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

    // Codex: re-pairing preserved the record's OLD localDeviceId, so the
    // confirmation wait was trivially satisfied by a signal from a PREVIOUS
    // attempt, before this attempt's own reciprocal exchange had any chance
    // to run — meaning `addPeer` could report success and leave the link
    // unauthorized moments later if the NEW callback actually failed.
    @Test func rePairingResetsStaleReciprocalConfirmationAndWaitsForAFreshOne() async {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "stale-dev-id", addedAt: Date(timeIntervalSince1970: 1))])
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: Links())
        manager.connectAll()
        // No confirmation for THIS attempt ever arrives.
        let error = await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765")
        #expect(error == .reciprocalPairingFailed)
        #expect(manager.peers.isEmpty)
    }

    @Test func rePairingSucceedsOnceAFreshReciprocalConfirmationArrives() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "stale-dev-id", addedAt: Date(timeIntervalSince1970: 1))])
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: Links())
        manager.connectAll()
        // A NEW, different device id proves the record picked up THIS
        // attempt's confirmation, not the stale one from before.
        confirmReciprocalPairing(on: manager, peerServerId: "srv-a", localDeviceId: "fresh-dev-id")
        #expect(await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765") == nil)
        #expect(try #require(manager.peers.first).localDeviceId == "fresh-dev-id")
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

    // The safety property that replaces the eviction `redeemPeer` used to do:
    // a peer redeem no longer invalidates an earlier record for the same
    // identity, so re-pairing can leave several device rows. Forgetting the
    // peer must take all of them, or a superseded token would stay valid
    // after the user revoked the peer.
    @Test func forgetRevokesEveryDeviceCarryingThePeersIdentity() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let first = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let second = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let other = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac C", peerServerId: "srv-c")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: nil, token: "t", protocolVersion: nil,
                               localDeviceId: first.deviceId, addedAt: Date())])
        var revoked: [String] = []
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer([:], requests: Requests()), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        manager.forget(peerId: "p1")
        #expect(pairing.validate(token: first.token) == nil)
        #expect(pairing.validate(token: second.token) == nil)
        #expect(revoked.sorted() == [first.deviceId, second.deviceId].sorted())
        // A different peer's access is untouched.
        #expect(pairing.validate(token: other.token) == other.deviceId)
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
