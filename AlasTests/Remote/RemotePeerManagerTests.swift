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

    /// Polls `requests`' most recent outgoing body for the counter-code an
    /// `addPeer` attempt minted on itself, up to ~200ms. `addPeer` generates
    /// this randomly and has no injection point, so tests that need to
    /// simulate a matching reciprocal confirmation capture the real value
    /// from the wire instead of fabricating one.
    private func awaitCapturedCounterCode(from requests: Requests) async -> String? {
        for _ in 0..<200 {
            if let last = requests.seen.last,
               let body = try? self.body(of: last),
               let ad = body["peer"] as? [String: Any],
               let code = ad["counterCode"] as? String {
                return code
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }

    /// Simulates A's reciprocal call landing WHILE `addPeer`'s confirmation
    /// wait is still polling — the real-world timing this represents.
    /// Captures the REAL counter-code this specific attempt minted, from
    /// its outgoing request body, rather than a fabricated one: a
    /// confirmation is now bound to the exact counter-code it redeems, so a
    /// simulated one has to carry the one `addPeer` is actually waiting for.
    @discardableResult
    private func confirmReciprocalPairing(on manager: RemotePeerManager, requests: Requests,
                                          peerServerId: String,
                                          peerName: String = "Mac A",
                                          origins: [String] = ["http://10.0.0.1:8765"],
                                          localDeviceId: String = "dev-a") -> Task<Void, Never> {
        Task {
            guard let redeemedCode = await awaitCapturedCounterCode(from: requests) else { return }
            await manager.handleInboundPeer(RemotePeerPairingRequest(
                peerServerId: peerServerId, peerName: peerName, origins: origins,
                counterCode: nil, localDeviceId: localDeviceId, redeemedCode: redeemedCode))
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
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
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

    // A's own /pair reply succeeding only proves OUR call to A worked, not
    // that A's reciprocal pair-back to US did — our
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
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links())
        manager.connectAll()
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        let start = Date()
        #expect(await manager.addPeer(link: linkFromA) == nil)
        // The manager's own timeout for this suite is 0.05s; resolving well
        // under it shows the wait picked up the confirmation rather than
        // idling out.
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
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC",
            localDeviceId: "dev-a", redeemedCode: "ABC123"))
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
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
        #expect(requests.seen.count == 1)
    }

    // A schedules its reciprocal call right after redeeming our code,
    // before A's own HTTP reply to OUR original request has even finished
    // transmitting — so A's reciprocal call can land on our /pair endpoint
    // and reach `handleInboundPeer` before our own `addPeer` has returned
    // from the network call that creates this record. Without buffering,
    // the "else" branch's lookup finds nothing and the ONLY confirmation
    // this attempt will ever get is silently dropped. `confirmReciprocalPairing`
    // fires as soon as the outgoing request appears, which can land before
    // `addPeer` has created the record at all — exercised here by the same
    // wait loop that checks the buffer on every poll, including its first.
    @Test func aReciprocalConfirmationThatArrivesBeforeTheRecordExistsIsNotLost() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests), links: Links())
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.localDeviceId == "dev-a")
    }

    // An unmatched confirmation buffered by an EARLIER, unrelated
    // attempt (one whose own addPeer never reached upsert) must not sit
    // around forever and then wrongly satisfy a LATER, different attempt's
    // wait for the same peer. It is isolated by carrying a different
    // counter-code from the one this attempt mints; this test also proves
    // the buffer is pruned on expiry rather than growing unbounded.
    @Test func aStaleBufferedConfirmationFromAnEarlierAttemptDoesNotSatisfyALaterOne() async {
        let manager = makeManager(
            pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
            links: Links(), reciprocalConfirmationTimeout: 0.02)
        // Simulates A's reciprocal call landing for a PRIOR attempt that
        // never got as far as creating a record (e.g. our own outbound leg
        // to A failed after this had already arrived), then going stale
        // before any add for "srv-a" actually happens.
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil,
            localDeviceId: "stale-dev", redeemedCode: "earlier-attempts-code"))
        try? await Task.sleep(nanoseconds: 40_000_000)   // outlast the 0.02s window
        // Nothing confirms THIS attempt — the stale buffered entry must not
        // stand in for it.
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        #expect(manager.peers.isEmpty)
    }

    // Keying the buffer by peer alone let a genuinely CURRENT
    // confirmation from an unrelated attempt for the same peer satisfy this
    // attempt merely by arriving inside the timeout window. Binding to the
    // exact counter-code this attempt minted rules that out regardless of
    // timing — this confirmation is fresh, not stale, and still must not match.
    @Test func aConfirmationForADifferentAttemptsCounterCodeNeverSatisfiesThisOne() async {
        let manager = makeManager(
            pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
            links: Links())
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil,
            localDeviceId: "other-attempt-dev", redeemedCode: "other-attempts-code"))
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
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC",
            localDeviceId: inbound.deviceId, redeemedCode: "ABC123"))
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
        let requests = Requests()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: links)
        manager.connectAll()
        let oldLink = try #require(links.byPeerId["p1"])
        // A fresh confirmation for THIS attempt — the record's OLD
        // localDeviceId ("dev-a" from the seeded store) must not be enough
        // on its own; see rePairingResetsStaleReciprocalConfirmation below.
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a", localDeviceId: "dev-a")
        #expect(await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765") == nil)
        #expect(manager.peers.count == 1)
        let peer = try #require(manager.peers.first)
        #expect(peer.id == "p1")
        #expect(peer.token == "tokA")
        #expect(peer.name == "Mac A")
        // The fresh advertisement's origins come first — see
        // rePairingCapsTheAccumulatedOriginsList for why — with the
        // previous record's origin backfilled after.
        #expect(peer.origins == ["http://10.0.0.9:8765", "http://10.0.0.1:8765"])
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

    // Re-pairing preserved the record's OLD localDeviceId, so the
    // confirmation wait was trivially satisfied by a signal from a PREVIOUS
    // attempt, before this attempt's own reciprocal exchange had any chance
    // to run — meaning `addPeer` could report success and leave the link
    // unauthorized moments later if the NEW callback actually failed. When the
    // fresh wait then genuinely times out, the previous, untouched
    // relationship is restored rather than destroyed — see
    // rePairingFailureRestoresThePreviousPeerRatherThanForgettingIt below.
    @Test func rePairingResetsStaleReciprocalConfirmationAndWaitsForAFreshOne() async throws {
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
        let peer = try #require(manager.peers.first)
        #expect(peer.token == "old-token")
        #expect(peer.localDeviceId == "stale-dev-id")
    }

    // Re-pairing an existing, working peer whose NEW reciprocal
    // exchange fails used to `forget()` unconditionally — destroying a
    // previous relationship that this attempt never touched and that could
    // still be entirely valid, and revoking a device grant that was never
    // actually superseded.
    @Test func rePairingFailureRestoresThePreviousPeerRatherThanForgettingIt() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let original = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: original.deviceId, addedAt: Date(timeIntervalSince1970: 1))])
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: Requests()),
                                  links: Links())
        manager.connectAll()
        // No confirmation for THIS re-pair attempt ever arrives.
        let error = await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765")
        #expect(error == .reciprocalPairingFailed)
        let peer = try #require(manager.peers.first)
        #expect(peer.token == "old-token")
        #expect(peer.origins == ["http://10.0.0.1:8765"])
        #expect(peer.localDeviceId == original.deviceId)
        // The previously-valid inbound device grant was never revoked.
        #expect(pairing.validate(token: original.token) == original.deviceId)
    }

    @Test func rePairingSucceedsOnceAFreshReciprocalConfirmationArrives() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "stale-dev-id", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links())
        manager.connectAll()
        // A NEW, different device id proves the record picked up THIS
        // attempt's confirmation, not the stale one from before.
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a", localDeviceId: "fresh-dev-id")
        #expect(await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765") == nil)
        #expect(try #require(manager.peers.first).localDeviceId == "fresh-dev-id")
    }

    // `handleInboundPeer`'s "peer already exists" branch used to write
    // `localDeviceId` directly onto the record, racing `addPeer`'s own
    // `upsert` (called right after the network reply returns), which resets
    // `localDeviceId` to nil — a confirmation landing while that network
    // call was still in flight was silently erased the instant `upsert` ran,
    // and `addPeer` then waited out the full timeout despite the exchange
    // having already succeeded. A delayed reply forces the confirmation to
    // land squarely inside that window.
    @Test func aReciprocalConfirmationForAnExistingPeerThatArrivesBeforeUpsertIsNotErased() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        let delayedPairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            try? await Task.sleep(nanoseconds: 30_000_000)
            return (Data(#"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairer: delayedPairer, links: Links())
        manager.connectAll()
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a", localDeviceId: "fresh-dev-id")
        #expect(await manager.addPeer(link: "http://10.0.0.9:8765/?code=ABC123&hosts=http%3A%2F%2F10.0.0.9%3A8765") == nil)
        #expect(try #require(manager.peers.first).localDeviceId == "fresh-dev-id")
    }

    // Our own outbound leg failing does not mean A's reciprocal leg did — A
    // can still redeem our counter-code and pair back even if OUR read of
    // A's reply is lost on the wire. That buffers a confirmation that
    // authorizes a device for A, so addPeer's failure path must check for it
    // rather than just returning, or that device would stand with no peer
    // row this attempt will ever create to forget it by.
    @Test func addPeerRevokesABufferedReciprocalDeviceWhenOurOwnLegFails() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let requests = Requests()
        var revoked: [String] = []
        // A delayed, always-failing reply gives the confirming task time to
        // land while addPeer's own call is still in flight, before it
        // resolves to .unreachable.
        let delayedPairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            try? await Task.sleep(nanoseconds: 20_000_000)
            throw URLError(.cannotConnectToHost)
        }, timeout: 1)
        let manager = makeManager(pairing: pairing, pairer: delayedPairer, links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a", localDeviceId: inbound.deviceId)
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .unreachable)
        #expect(manager.peers.isEmpty)
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // The far side's own retries run on their own schedule, independent of
    // whether this attempt already gave up: its reciprocal call can land
    // well after addPeer has already returned failure, with nothing left
    // waiting to claim it. It must be revoked the moment it arrives rather
    // than buffered on the chance some unrelated later callback sweeps it
    // out — or left standing forever if none ever does.
    @Test func aReciprocalCallbackArrivingAfterTheAttemptAlreadyEndedIsRevokedOnArrival() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let requests = Requests()
        var revoked: [String] = []
        let manager = makeManager(pairing: pairing, pairer: pairer([:], requests: requests), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .unreachable)
        let sent = try body(of: try #require(requests.seen.first))
        let counterCode = try #require((sent["peer"] as? [String: Any])?["counterCode"] as? String)
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil,
            localDeviceId: inbound.deviceId, redeemedCode: counterCode))
        #expect(manager.peers.isEmpty)
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // If the user clicks Forget while addPeer is still waiting for
    // confirmation, a subsequent callback for that same attempt has nothing
    // left to attach itself to. Reporting success with no peer row to show
    // for it would be worse than reporting failure and revoking the device
    // the callback just authorized.
    @Test func aConfirmationForAPeerForgottenWhileWaitingIsTreatedAsCancelled() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let requests = Requests()
        var revoked: [String] = []
        let manager = makeManager(pairing: pairing,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        Task {
            while manager.peers.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
            manager.forget(peerId: manager.peers[0].id)
            guard let redeemedCode = await self.awaitCapturedCounterCode(from: requests) else { return }
            await manager.handleInboundPeer(RemotePeerPairingRequest(
                peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"],
                counterCode: nil, localDeviceId: inbound.deviceId, redeemedCode: redeemedCode))
        }
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        #expect(manager.peers.isEmpty)
        #expect(revoked.contains(inbound.deviceId))
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // Re-pairing an existing, working peer whose own outbound leg reports
    // .unreachable never even reaches upsert, so the existing peer row is
    // untouched — the far side may still redeem the counter-code and
    // authorize a device that this Mac now depends on for that direction of
    // the relationship. Revoking it just because THIS leg separately failed
    // would break a connection that never actually needed rescuing, even
    // though a peer row for it already exists.
    @Test func aReciprocalDeviceForAnExistingPeerSurvivesWhenOurOwnLegIsUnreachable() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let requests = Requests()
        var revoked: [String] = []
        let manager = makeManager(store: store, pairing: pairing, pairer: pairer([:], requests: requests), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a", localDeviceId: inbound.deviceId)
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .unreachable)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.token == "old-token")
        #expect(revoked.isEmpty)
        #expect(pairing.validate(token: inbound.token) == inbound.deviceId)
    }

    // Forgetting a peer while re-pairing it is still in flight — before the
    // far side's real identity is even known, so no peer row exists yet for
    // a missing-record check to catch — must not have the completed network
    // reply resurrect the row `upsert` would otherwise happily recreate.
    @Test func forgettingAPeerDuringItsOwnInFlightRePairIsNotUndoneByTheReply() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        // A delayed reply gives a concurrent Forget time to land before
        // addPeer resumes and would otherwise upsert a fresh record from it.
        let delayedPairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            try? await Task.sleep(nanoseconds: 20_000_000)
            return (Data(#"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairer: delayedPairer, links: Links())
        manager.connectAll()
        Task {
            while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
            manager.forget(peerId: "p1")
        }
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .cancelled)
        #expect(manager.peers.isEmpty)
    }

    // The same in-flight-Forget race, but the far side's reciprocal call
    // also lands — proving it is revoked rather than silently
    // re-authorizing the peer the user just removed.
    @Test func aReciprocalConfirmationArrivingAfterAnInFlightRePairWasForgottenIsRevoked() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        var revoked: [String] = []
        let delayedPairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            try? await Task.sleep(nanoseconds: 20_000_000)
            return (Data(#"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairing: pairing, pairer: delayedPairer, links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        manager.connectAll()
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        Task {
            while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
            manager.forget(peerId: "p1")
        }
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a", localDeviceId: inbound.deviceId)
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .cancelled)
        #expect(manager.peers.isEmpty)
        #expect(revoked.contains(inbound.deviceId))
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // Multiple stored peers can share an origin — a link's own `hosts`
    // param includes every address this Mac advertises, localhost among
    // them — so identifying the row being re-paired by origin overlap
    // could name the wrong one. This re-pairs "srv-b" specifically, while
    // "srv-a" (untouched, but sharing the localhost origin) is still
    // present, proving the forgotten-during-flight check is keyed to the
    // returned identity rather than any shared address.
    @Test func forgettingTheRightPeerDuringARePairIsDetectedEvenWhenAnotherPeerSharesAnOrigin() async throws {
        let store = InMemoryPeerStore()
        store.save([
            RemotePeer(id: "p1", serverId: "srv-a", name: "A", origins: ["http://localhost:8765", "http://10.0.0.1:8765"],
                       lastOrigin: "http://10.0.0.1:8765", token: "old-token-a", protocolVersion: 1,
                       localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1)),
            RemotePeer(id: "p2", serverId: "srv-b", name: "B", origins: ["http://localhost:8765", "http://10.0.0.2:8765"],
                       lastOrigin: "http://10.0.0.2:8765", token: "old-token-b", protocolVersion: 1,
                       localDeviceId: "dev-b", addedAt: Date(timeIntervalSince1970: 2)),
        ])
        let requests = Requests()
        let delayedPairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            try? await Task.sleep(nanoseconds: 20_000_000)
            return (Data(#"{"token":"tokB","serverId":"srv-b","name":"Mac B"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairer: delayedPairer, links: Links())
        manager.connectAll()
        Task {
            while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
            manager.forget(peerId: "p2")   // forgets "srv-b", the peer actually being re-paired
        }
        let link = "http://localhost:8765/?code=ABC123&hosts=http%3A%2F%2Flocalhost%3A8765%2Chttp%3A%2F%2F10.0.0.2%3A8765"
        let error = await manager.addPeer(link: link)
        #expect(error == .cancelled)
        #expect(manager.peers.count == 1)
        #expect(manager.peers.first?.serverId == "srv-a")
    }

    // Mirrors the initiator-side forgotten-during-flight fix, but for the
    // RESPONDER: pairing back (redeeming the far side's counter-code) also
    // awaits a network round trip, during which the user can forget the
    // existing peer this re-pair concerns. The reply must not resurrect the
    // outbound side of that relationship.
    @Test func forgettingAPeerDuringOurOwnReciprocalPairBackDoesNotResurrectIt() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-b", name: "old", origins: ["http://10.0.0.2:8765"],
                               lastOrigin: "http://10.0.0.2:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-b", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        var revoked: [String] = []
        let delayedPairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            try? await Task.sleep(nanoseconds: 20_000_000)
            return (Data(#"{"token":"tokB","serverId":"srv-b","name":"Mac B"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairing: pairing, pairer: delayedPairer, links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        manager.connectAll()
        Task {
            while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
            manager.forget(peerId: "p1")
        }
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "CC",
            localDeviceId: inbound.deviceId, redeemedCode: "ABC123"))
        #expect(manager.peers.isEmpty)
        #expect(revoked.contains(inbound.deviceId))
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // A Mac with more advertised addresses than the shared bound (several
    // interfaces plus configured allowed hosts) would otherwise have the
    // receiving Mac reject the advertisement outright — it can never tell
    // "too many legitimate addresses" apart from a hostile one.
    @Test func addPeerCapsAdvertisedOriginsToTheSharedMaximum() async throws {
        let manyOrigins = (1...12).map { "http://10.0.0.\($0):8765" }
        let identity = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "Mac B", origins: manyOrigins)
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links(), identity: identity)
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        let sent = try body(of: try #require(requests.seen.first))
        let ad = try #require(sent["peer"] as? [String: Any])
        #expect(ad["origins"] as? [String] == Array(manyOrigins.prefix(RemotePairingLink.maxOrigins)))
    }

    // Mirrors the initiator-side origin cap, but for the responder pairing
    // back to redeem the far side's counter-code.
    @Test func handleInboundPeerCapsAdvertisedOriginsWhenPairingBack() async throws {
        let manyOrigins = (1...12).map { "http://10.0.0.\($0):8765" }
        let identity = RemotePeerManager.LocalIdentity(serverId: "srv-a", name: "Mac A", origins: manyOrigins)
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokB","serverId":"srv-b","name":"Mac B"}"#)], requests: requests),
                                  links: Links(), identity: identity)
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://10.0.0.9:8765"], counterCode: "CC",
            localDeviceId: "dev-b", redeemedCode: "ABC123"))
        let sent = try body(of: try #require(requests.seen.first))
        let ad = try #require(sent["peer"] as? [String: Any])
        #expect(ad["origins"] as? [String] == Array(manyOrigins.prefix(RemotePairingLink.maxOrigins)))
    }

    // Each individual advertisement is capped, but repeated re-pairs across
    // network changes append to the stored record without any overall
    // bound. The fresh advertisement — already bounded, and including
    // whatever address this exchange just confirmed works — is prioritized,
    // with only the remaining capacity backfilled from the previous record.
    @Test func rePairingCapsTheAccumulatedOriginsList() async throws {
        let staleOrigins = (1...7).map { "http://old-\($0).example:8765" }
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: staleOrigins,
                               lastOrigin: staleOrigins[0], token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-a", addedAt: Date(timeIntervalSince1970: 1))])
        let freshOrigins = (1...5).map { "http://10.0.0.\($0):8765" }
        let requests = Requests()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links())
        manager.connectAll()
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        let hosts = freshOrigins.map(RemotePairingLink.encodeOrigin).joined(separator: ",")
        let link = "http://10.0.0.1:8765/?code=ABC123&hosts=\(hosts)"
        #expect(await manager.addPeer(link: link) == nil)
        let peer = try #require(manager.peers.first)
        #expect(peer.origins.count == RemotePairingLink.maxOrigins)
        #expect(Array(peer.origins.prefix(freshOrigins.count)) == freshOrigins)
    }

    // A's reciprocal callback must claim the SAME identity its original
    // reply established this record under. A callback claiming a DIFFERENT
    // identity has only proven it somehow obtained our counter-code, not
    // that it IS the peer we started this exchange with — accepting it
    // would authorize a device recorded under an identity `forget` never
    // checks (it sweeps by the record's STORED serverId), letting that
    // device survive indefinitely even after the user forgets this peer.
    @Test func aReciprocalConfirmationClaimingADifferentIdentityThanTheOriginalReplyIsRejected() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let requests = Requests()
        var revoked: [String] = []
        let manager = makeManager(pairing: pairing,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-x","name":"Mac X"}"#)], requests: requests),
                                  links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        let mismatched = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac Y", peerServerId: "srv-y")
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-y", localDeviceId: mismatched.deviceId)
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        #expect(manager.peers.isEmpty)
        #expect(revoked.contains(mismatched.deviceId))
        #expect(pairing.validate(token: mismatched.token) == nil)
    }

    // A confirmation that arrives with no addPeer attempt left waiting
    // for its counter-code (the attempt it belonged to already gave up, or
    // never existed) sits buffered until swept by expiry — the device it
    // authorized must be revoked at that point, not just silently dropped.
    @Test func aNeverClaimedBufferedConfirmationIsRevokedOnceItExpires() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        var revoked: [String] = []
        let manager = makeManager(pairing: pairing,
                                  pairer: pairer([:], requests: Requests()),
                                  links: Links(), reciprocalConfirmationTimeout: 0.02)
        manager.onRevokeDevice = { revoked.append($0) }
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil,
            localDeviceId: inbound.deviceId, redeemedCode: "orphaned-code"))
        try? await Task.sleep(nanoseconds: 40_000_000)   // outlast the 0.02s window
        // A later, unrelated confirmation triggers the sweep that finds the
        // first one expired.
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-c", peerName: "Mac C", origins: ["http://10.0.0.3:8765"], counterCode: nil,
            localDeviceId: "dev-c", redeemedCode: "unrelated-code"))
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // An ended attempt's tombstone must outlive `reciprocalConfirmationTimeout`:
    // the far side can still redeem the underlying counter-code for as long
    // as `RemotePairingService.codeTTL` keeps it valid, well past this Mac's
    // own much shorter confirmation wait. Pruning the tombstone on the
    // shorter window would let a redemption in that gap fall through as an
    // ordinary arrival instead of being recognized as ended.
    @Test func anEndedCounterCodeTombstoneOutlivesTheConfirmationTimeout() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let requests = Requests()
        var revoked: [String] = []
        let manager = makeManager(pairing: pairing, pairer: pairer([:], requests: requests),
                                  links: Links(), reciprocalConfirmationTimeout: 0.02)
        manager.onRevokeDevice = { revoked.append($0) }
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .unreachable)
        let sent = try body(of: try #require(requests.seen.first))
        let counterCode = try #require((sent["peer"] as? [String: Any])?["counterCode"] as? String)
        try? await Task.sleep(nanoseconds: 40_000_000)   // outlast the 0.02s confirmation timeout
        // A later, unrelated confirmation triggers the same sweep that
        // prunes pendingReciprocalConfirmations on the short window, but
        // must leave this ended tombstone alone.
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-c", peerName: "Mac C", origins: ["http://10.0.0.3:8765"], counterCode: nil,
            localDeviceId: "dev-c", redeemedCode: "unrelated-code"))
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil,
            localDeviceId: inbound.deviceId, redeemedCode: counterCode))
        #expect(revoked == [inbound.deviceId])
        #expect(pairing.validate(token: inbound.token) == nil)
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
