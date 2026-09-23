import Testing
import Foundation
import CryptoKit
@testable import Alas

@MainActor
struct RemotePeerManagerTests {
    @Test(arguments: ["cancel", "revoke"], [false, true])
    func outboundRollbackCannotRestoreInvalidInboundPredecessor(action: String, hasOlderPeer: Bool) async throws {
        for approvedOutbound in [false, true] {
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = RemoteIdentityCrypto.publicKeyString(key.publicKey)
            let pairing = RemotePairingService(store: InMemoryDeviceStore())
            let store = InMemoryPeerStore()
            let olderGrant = pairing.issueApprovedPeer(deviceName: "Old", peerServerId: "srv-a")
            pairing.commitApprovedPeer(deviceId: olderGrant.deviceId)
            let olderPeer = RemotePeer(id: "older", serverId: "srv-a", name: "Old", origins: ["http://10.0.0.1:8765"],
                lastOrigin: nil, token: "older", publicKey: publicKey, protocolVersion: nil,
                localDeviceId: olderGrant.deviceId, addedAt: Date())
            let baseline = hasOlderPeer ? [olderPeer] : []
            store.save(baseline)
            let pairer = RemotePeerPairer(fetch: { request in
                let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                let challenge = try #require(body["challenge"] as? String)
                let code = try #require(body["code"] as? String)
                let proof = try #require(RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: key))
                let data = try JSONSerialization.data(withJSONObject: ["token": code, "serverId": "srv-a",
                    "name": "A", "publicKey": proof.publicKey, "signature": proof.signature])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let manager = makeManager(store: store, pairing: pairing, pairer: pairer, links: Links(),
                identity: .init(serverId: "srv-b", name: "B", origins: identity.origins, publicKey: publicKey),
                reciprocalConfirmationTimeout: 0.2)
            let grant = pairing.issueApprovedPeer(deviceName: "A", peerServerId: "srv-a")
            manager.noteApprovedPeerPairingArrived(requestID: "inbound",
                request: .init(peerServerId: "srv-a", peerName: "A", origins: olderPeer.origins,
                    peerPublicKey: publicKey, counterCode: "inbound", localDeviceId: grant.deviceId, redeemedCode: ""),
                localPeer: .init(serverID: "srv-b", publicKey: "local", name: "B", origins: identity.origins))
            #expect(await manager.handleInboundApprovedPeer(requestID: "inbound"))
            let outbound = Task {
                if approvedOutbound {
                    return await manager.addApprovedPeer(expectedPeer: .init(serverID: "srv-a", publicKey: publicKey,
                        name: "A", origins: olderPeer.origins)) { _ in
                            .paired(token: "outbound", serverId: "srv-a", name: "A", publicKey: publicKey, origin: olderPeer.origins[0])
                        }
                }
                return await manager.addPeer(code: "outbound", origins: olderPeer.origins)
            }
            for _ in 0..<100 where manager.peers.first?.token != "outbound" {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(manager.peers.first?.token == "outbound")
            if action == "cancel" { manager.cancelApprovedPairing(requestID: "inbound") }
            else { pairing.revoke(deviceId: grant.deviceId) }
            #expect(await outbound.value == .reciprocalPairingFailed)
            #expect(pairing.validate(token: grant.token) == nil)
            #expect(manager.peers == baseline)
            #expect(store.saved == baseline)
        }
    }

    @Test(arguments: ["keep", "cancel", "revoke"], [false, true])
    func approvedCancellationRestoresPeerCommittedDuringItsNetworkWait(predecessorAction: String, hasOlderPeer: Bool) async throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = RemoteIdentityCrypto.publicKeyString(key.publicKey)
        let localPeer = ApprovalPeer(serverID: "srv-b", publicKey: "local", name: "B", origins: identity.origins)
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let store = InMemoryPeerStore()
        let olderGrant = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Old", peerServerId: "srv-a")
        let olderPeer = RemotePeer(id: "older", serverId: "srv-a", name: "Old", origins: ["http://10.0.0.1:8765"],
            lastOrigin: nil, token: "older", publicKey: publicKey, protocolVersion: nil,
            localDeviceId: olderGrant.deviceId, addedAt: Date())
        let baseline = hasOlderPeer ? [olderPeer] : []
        store.save(baseline)
        var entered: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        let pairer = RemotePeerPairer(fetch: { request in
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            let code = try #require(body["code"] as? String)
            if code == "code-a" {
                await withCheckedContinuation { continuation in
                    release = continuation
                    entered?.resume()
                    entered = nil
                }
            }
            let challenge = try #require(body["challenge"] as? String)
            let proof = try #require(RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: key))
            let data = try JSONSerialization.data(withJSONObject: ["token": code, "serverId": "srv-a",
                "name": "A", "publicKey": proof.publicKey, "signature": proof.signature])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let manager = makeManager(store: store, pairing: pairing, pairer: pairer, links: Links())
        func begin(_ id: String) -> RemotePeerRedeemResult {
            let grant = pairing.issueApprovedPeer(deviceName: "A", peerServerId: "srv-a")
            manager.noteApprovedPeerPairingArrived(requestID: id,
                request: RemotePeerPairingRequest(peerServerId: "srv-a", peerName: "A", origins: ["http://10.0.0.1:8765"],
                    peerPublicKey: publicKey, counterCode: "code-" + id, localDeviceId: grant.deviceId, redeemedCode: ""), localPeer: localPeer)
            return grant
        }
        let grantA = begin("a")
        var taskA: Task<Bool, Never>!
        await withCheckedContinuation { continuation in
            entered = continuation
            taskA = Task { await manager.handleInboundApprovedPeer(requestID: "a") }
        }
        let grantB = begin("b")
        #expect(await manager.handleInboundApprovedPeer(requestID: "b"))
        let peerB = try #require(manager.peers.first)
        let grantC = begin("c")
        #expect(await manager.handleInboundApprovedPeer(requestID: "c"))
        let peerC = try #require(manager.peers.first)
        release?.resume()
        #expect(await taskA.value)
        #expect(manager.peers.first?.token == "code-a")
        if predecessorAction == "cancel" {
            manager.cancelApprovedPairing(requestID: "b")
            manager.cancelApprovedPairing(requestID: "c")
        }
        if predecessorAction == "revoke" {
            pairing.revoke(deviceId: grantB.deviceId)
            pairing.revoke(deviceId: grantC.deviceId)
        }
        manager.cancelApprovedPairing(requestID: "a")
        #expect(pairing.validate(token: grantA.token) == nil)
        if predecessorAction != "keep" {
            #expect(manager.peers == baseline)
            #expect(store.saved == baseline)
        } else {
            #expect(manager.peers == [peerC])
            #expect(store.saved == [peerC])
            #expect(pairing.validate(token: grantB.token) == grantB.deviceId)
            #expect(pairing.validate(token: grantC.token) == grantC.deviceId)
            manager.cancelApprovedPairing(requestID: "c")
            #expect(manager.peers == [peerB])
            manager.cancelApprovedPairing(requestID: "b")
            #expect(manager.peers == baseline)
        }
        #expect(pairing.validate(token: grantB.token) == nil)
        #expect(pairing.validate(token: grantC.token) == nil)
    }

    @Test func unrelatedSavesPreserveOlderDurablePeerDuringApprovedWait() async throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let local = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "B", origins: identity.origins, publicKey: key)
        let store = InMemoryPeerStore()
        let old = RemotePeer(id: "old", serverId: "srv-a", name: "A", origins: ["http://10.0.0.1:8765"],
            lastOrigin: nil, token: "old", publicKey: key, protocolVersion: nil, localDeviceId: nil, addedAt: Date())
        let unrelated = RemotePeer(id: "other", serverId: "srv-c", name: "C", origins: ["http://10.0.0.3:8765"],
            lastOrigin: nil, token: "other", publicKey: key, protocolVersion: nil, localDeviceId: nil, addedAt: Date())
        store.save([old, unrelated])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links, identity: local,
                                  reciprocalConfirmationTimeout: 0.2)
        manager.connectAll()
        let peer = ApprovalPeer(serverID: "srv-a", publicKey: key, name: "A", origins: old.origins)
        let attempt = Task { await manager.addApprovedPeer(expectedPeer: peer) { _ in
            .paired(token: "new", serverId: peer.serverID, name: peer.name, publicKey: key, origin: peer.origins[0])
        } }
        for _ in 0..<100 {
            if manager.peers.first?.token == "new" { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(manager.peers.first?.token == "new")
        links.byPeerId[unrelated.id]?.emit(.hello(serverId: "srv-c", name: "Renamed C", protocolVersion: 1, federationEnabled: true))
        #expect(store.saved.first?.token == "old")
        #expect(store.saved.last?.name == "Renamed C")
        #expect(await attempt.value == .reciprocalPairingFailed)
        #expect(manager.peers.first == old)
        #expect(store.saved.last?.name == "Renamed C")
        manager.disconnectAll()
    }

    @Test func approvedPairKeepsFrozenReturnOriginsAndRejectsWrongRemotePin() async {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let local = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "B", origins: ["http://10.0.0.99:8765"], publicKey: key)
        let frozen = ApprovalPeer(serverID: "srv-b", publicKey: key, name: "B", origins: identity.origins)
        let peer = ApprovalPeer(serverID: "srv-a", publicKey: key, name: "A", origins: ["http://10.0.0.1:8765"])
        let manager = makeManager(pairer: pairer([:], requests: Requests()), links: Links(), identity: local)
        let result = await manager.addApprovedPeer(expectedPeer: peer, localPeer: frozen) { ad in
            #expect(ad.origins == frozen.origins)
            return .paired(token: "wrong", serverId: peer.serverID, name: peer.name, publicKey: nil, origin: peer.origins[0])
        }
        #expect(result == .identityUnproven)
        #expect(manager.peers.isEmpty)
    }

    @Test func forgetDuringApprovedRedemptionPreventsPublication() async {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let local = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "B", origins: identity.origins, publicKey: key)
        let store = InMemoryPeerStore()
        let old = RemotePeer(id: "old", serverId: "srv-a", name: "A", origins: ["http://10.0.0.1:8765"],
            lastOrigin: nil, token: "old", publicKey: key, protocolVersion: nil, localDeviceId: nil, addedAt: Date())
        store.save([old])
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: Links(), identity: local)
        let peer = ApprovalPeer(serverID: "srv-a", publicKey: key, name: "A", origins: old.origins)
        let result = await manager.addApprovedPeer(expectedPeer: peer) { _ in
            manager.forget(peerId: old.id)
            return .paired(token: "new", serverId: peer.serverID, name: peer.name, publicKey: key, origin: peer.origins[0])
        }
        #expect(result == .cancelled)
        #expect(manager.peers.isEmpty)
        #expect(store.saved.isEmpty)
    }

    @Test(arguments: [false, true])
    func approvedInboundCancellationRestoresOnlyItsOwnPreviousPeer(cancelBeforeReply: Bool) async throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = RemoteIdentityCrypto.publicKeyString(key.publicKey)
        let localKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let localPeer = ApprovalPeer(serverID: "srv-b", publicKey: localKey, name: "B", origins: identity.origins)
        let store = InMemoryPeerStore()
        let devices = InMemoryDeviceStore()
        let pairing = RemotePairingService(store: devices)
        let oldGrant = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "A", peerServerId: "srv-a")
        let old = RemotePeer(id: "existing", serverId: "srv-a", name: "Old", origins: ["http://10.0.0.1:8765"],
            lastOrigin: nil, token: "old-token", publicKey: publicKey, protocolVersion: nil,
            localDeviceId: oldGrant.deviceId, addedAt: Date())
        store.save([old])
        let manager = makeManager(store: store, pairing: pairing,
            pairer: provingPairer(serverId: "srv-a", key: key, requests: Requests()), links: Links())
        let fresh = pairing.issueApprovedPeer(deviceName: "A", peerServerId: "srv-a")
        let request = RemotePeerPairingRequest(peerServerId: "srv-a", peerName: "A", origins: old.origins,
            peerPublicKey: publicKey, counterCode: "fresh-code", localDeviceId: fresh.deviceId, redeemedCode: "")
        manager.noteApprovedPeerPairingArrived(requestID: "attempt", request: request, localPeer: localPeer)
        if cancelBeforeReply { manager.cancelApprovedPairing(requestID: "attempt") }
        #expect(await manager.handleInboundApprovedPeer(requestID: "attempt") == !cancelBeforeReply)
        manager.cancelApprovedPairing(requestID: "attempt")
        #expect(manager.peers == [old])
        #expect(store.saved == [old])
        #expect(pairing.validate(token: oldGrant.token) == oldGrant.deviceId)
        #expect(pairing.validate(token: fresh.token) == nil)
    }

    @Test func approvedLostReplyRevokesAttemptDeviceEvenWhenOlderPeerExists() async throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let local = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "B", origins: identity.origins, publicKey: key)
        let store = InMemoryPeerStore()
        let devices = InMemoryDeviceStore()
        let pairing = RemotePairingService(store: devices)
        let oldGrant = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "A", peerServerId: "srv-a")
        let old = RemotePeer(id: "old", serverId: "srv-a", name: "A", origins: ["http://10.0.0.1:8765"],
            lastOrigin: nil, token: "old", publicKey: key, protocolVersion: nil, localDeviceId: oldGrant.deviceId, addedAt: Date())
        store.save([old])
        let manager = makeManager(store: store, pairing: pairing, pairer: pairer([:], requests: Requests()), links: Links(), identity: local)
        let peer = ApprovalPeer(serverID: "srv-a", publicKey: key, name: "A", origins: old.origins)
        var freshToken = ""
        #expect(await manager.addApprovedPeer(expectedPeer: peer) { ad in
            let result = try! pairing.redeemPeer(code: ad.counterCode!, deviceName: "A", peerServerId: "srv-a")
            freshToken = result.token
            await manager.handleInboundPeer(RemotePeerPairingRequest(peerServerId: "srv-a", peerName: "A", origins: old.origins,
                peerPublicKey: key, counterCode: nil, localDeviceId: result.deviceId, redeemedCode: ad.counterCode!))
            return .unreachable
        } == .unreachable)
        #expect(pairing.validate(token: freshToken) == nil)
        #expect(pairing.validate(token: oldGrant.token) == oldGrant.deviceId)
        #expect(store.saved == [old])
    }

    @Test func approvedPairRequiresPersistentIdentityBeforeNetwork() async {
        let manager = makeManager(pairer: pairer([:], requests: Requests()), links: Links())
        let peer = ApprovalPeer(serverID: "other", publicKey: "key", name: "Other", origins: ["http://10.0.0.1:8765"])
        let result = await manager.addApprovedPeer(expectedPeer: peer) { _ in
            Issue.record("Missing local identity must reject before redemption")
            return .unreachable
        }
        #expect(result == .identityUnproven)
    }

    @Test func approvedPairWaitsForItsReciprocalAndPersistsOnlyOnSuccess() async throws {
        let store = InMemoryPeerStore()
        let devices = InMemoryDeviceStore()
        let pairing = RemotePairingService(store: devices)
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let peerKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let local = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "B", origins: identity.origins, publicKey: key)
        let manager = makeManager(store: store, pairing: pairing, pairer: pairer([:], requests: Requests()),
                                  links: Links(), identity: local)
        let peer = ApprovalPeer(serverID: "srv-a", publicKey: peerKey, name: "A", origins: ["http://10.0.0.1:8765"])
        let result = await manager.addApprovedPeer(expectedPeer: peer) { ad in
            #expect(store.saved.isEmpty)
            let code = ad.counterCode!
            let grant = try! pairing.redeemPeer(code: code, deviceName: "A", peerServerId: "srv-a")
            #expect(devices.saved.isEmpty)
            await manager.handleInboundPeer(RemotePeerPairingRequest(peerServerId: "srv-a", peerName: "A",
                origins: peer.origins, peerPublicKey: peerKey, counterCode: nil,
                localDeviceId: grant.deviceId, redeemedCode: code))
            return .paired(token: "outbound", serverId: "srv-a", name: "A", publicKey: peerKey, origin: peer.origins[0])
        }
        #expect(result == nil)
        #expect(store.saved.first?.token == "outbound")
        #expect(devices.saved.count == 1)
    }

    @Test func approvedPairNeverPersistsUnconfirmedPeer() async {
        let store = InMemoryPeerStore()
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let local = RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "B", origins: identity.origins, publicKey: key)
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: Links(), identity: local)
        let peer = ApprovalPeer(serverID: "srv-a", publicKey: key, name: "A", origins: ["http://10.0.0.1:8765"])
        let result = await manager.addApprovedPeer(expectedPeer: peer) { _ in
            .paired(token: "new", serverId: peer.serverID, name: peer.name, publicKey: key, origin: peer.origins[0])
        }
        #expect(result == .reciprocalPairingFailed)
        #expect(store.saved.isEmpty)
        #expect(manager.peers.isEmpty)
    }

    @MainActor
    final class FakeLink: RemotePeerConnecting {
        var state: RemotePeerConnection.State = .idle
        var connectCalls = 0
        var disconnectCalls = 0
        var sent: [RemoteClientMessage] = []
        let emit: @MainActor (RemotePeerConnection.Event) -> Void
        init(emit: @escaping @MainActor (RemotePeerConnection.Event) -> Void) { self.emit = emit }
        func connect() { connectCalls += 1 }
        func disconnect() { disconnectCalls += 1 }
        func send(_ message: RemoteClientMessage) { sent.append(message) }
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

    @Test func addPeerWithCodeAndOriginsRefusesEmptyInputWithoutNetwork() async {
        let requests = Requests()
        let manager = makeManager(pairer: pairer([:], requests: requests), links: Links())
        #expect(await manager.addPeer(code: "ABC123", origins: []) == .invalidLink)
        #expect(await manager.addPeer(code: "  ", origins: ["http://10.0.0.1:8765"]) == .invalidLink)
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

    // The rollback above removes the peer from `peers` before disconnecting
    // its link, so the link's OWN `.stateChanged(.idle)` — fired
    // synchronously inside a real `disconnect()` — cannot find the peer to
    // announce it by; `removeProvisionalPeer` must announce the removal
    // itself, the same way `forget` already does, or `FederatedSessionsProvider`
    // keeps treating a peer that briefly went `.online` as still there.
    @Test func addPeerRollbackAnnouncesFederationAvailabilityForTheRemovedPeer() async {
        let requests = Requests()
        let store = InMemoryPeerStore()
        let links = Links()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: links)
        var events: [FederatedPeerLinkEvent] = []
        manager.onFederationEvent = { events.append($0) }
        manager.connectAll()
        // Nothing ever calls handleInboundPeer for "srv-a": same rollback
        // path as the test above, through `removeProvisionalPeer`.
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        let announced = events.compactMap { event -> String? in
            if case .availabilityChanged(let serverId) = event { return serverId }
            return nil
        }
        #expect(announced == ["srv-a"])
    }

    // A first-time addPeer's own reciprocal wait can time out while a
    // completely separate, concurrent INBOUND exchange for the SAME
    // identity is still awaiting its own pair-back reply — it has not
    // called `upsert` yet, so the timed-out attempt's ownership check still
    // names it. Rolling back with `forget` semantics here would bump the
    // shared forget generation and fail that unrelated exchange's own
    // generation check purely as collateral damage from a timeout it has
    // nothing to do with; only this attempt's own provisional row may be
    // removed.
    @Test func addPeerTimeoutDoesNotFailAConcurrentInboundExchangeStillAwaitingItsOwnReply() async throws {
        let requests = Requests()
        let pairer = RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            if req.url!.host == "10.0.0.9" {
                // Still in flight when addPeer's own timeout fires below.
                try? await Task.sleep(nanoseconds: 150_000_000)
                return (Data(#"{"token":"tokB","serverId":"srv-a","name":"Mac A"}"#.utf8),
                        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(#"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(pairer: pairer, links: Links(), reciprocalConfirmationTimeout: 0.05)
        manager.connectAll()

        // Nothing ever confirms this attempt's own counter-code, so its own
        // wait times out and rolls back.
        async let addResult: RemotePeerManager.AddError? = manager.addPeer(link: linkFromA)
        // While that rollback is pending, a separate inbound exchange for
        // the same identity redeems ITS OWN counter-code and starts pairing
        // back — dialing the slow origin above, still unresolved when
        // addPeer's own timeout fires.
        while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        async let inbound: Void = manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.9:8765"], counterCode: "INBOUND-CODE",
            localDeviceId: "device-for-a", redeemedCode: "irrelevant"))

        let error = await addResult
        _ = await inbound
        #expect(error == .reciprocalPairingFailed)
        // The unrelated inbound exchange's own success must survive
        // addPeer's rollback, not be discarded by a generation bump that
        // rollback had no business causing.
        let peer = try #require(manager.peers.first)
        #expect(peer.localDeviceId == "device-for-a")
        #expect(peer.token == "tokB")
    }

    // `Task.sleep` throws immediately on a cancelled task rather than
    // actually sleeping, and a bare `try?` around it discards that signal.
    // Without an explicit cancellation check, the wait loop would busy-spin
    // this MainActor-isolated method with no real delay between iterations
    // until the real-time deadline elapsed, freezing the UI for the whole
    // window instead of returning promptly.
    @Test func addPeerExitsPromptlyWhenItsOwnTaskIsCancelledWhileWaiting() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links(), reciprocalConfirmationTimeout: 2)
        manager.connectAll()
        let task = Task { await manager.addPeer(link: linkFromA) }
        while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        let start = Date()
        _ = await task.value
        #expect(Date().timeIntervalSince(start) < 1.0, "cancellation must interrupt the wait promptly, not busy-spin until the real-time deadline")
    }

    // A completely separate, concurrent exchange for the SAME identity
    // (e.g. an inbound pairing) can succeed and update this same row while
    // this attempt's own wait is still running. When this attempt's own
    // wait then times out, it must not clobber that newer, unrelated
    // success — only roll back if the row still holds exactly what THIS
    // attempt's own upsert wrote.
    @Test func addPeerTimeoutDoesNotClobberANewerConcurrentPairing() async throws {
        let requests = Requests()
        let manager = makeManager(pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: Links(), reciprocalConfirmationTimeout: 0.02)
        manager.connectAll()
        // Nothing ever confirms this attempt's OWN counter-code — its wait
        // will time out. While it's waiting, a completely separate,
        // concurrent exchange for the SAME identity succeeds and updates
        // the row with a newer device.
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await manager.handleInboundPeer(RemotePeerPairingRequest(
                peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "OTHER",
                localDeviceId: "newer-device", redeemedCode: "OTHER-REDEEMED"))
        }
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)
        // The newer, concurrent exchange's own success must survive this
        // attempt's own, unrelated timeout — not be forgotten out from
        // under it.
        let peer = try #require(manager.peers.first)
        #expect(peer.localDeviceId == "newer-device")
    }

    // Two overlapping outbound adds for the same peer: EARLY's own
    // reciprocal confirmation arrives and updates only localDeviceId
    // directly — bypassing upsert entirely — while LATE's own upsert has
    // since overwritten the row's other fields. When LATE's own wait then
    // times out, its rollback must still be recognized as legitimate (it
    // is still the last one to have upserted — EARLY's confirmation never
    // touches ownership) and must revert to EARLY's own state — the one
    // that actually got confirmed — without discarding EARLY's
    // just-arrived, more recent confirmation.
    @Test func addPeerRollbackPreservesAnEarlierSiblingsConfirmedDeviceWhileRestoringItsOwnState() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "old-device", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        // Both siblings' own outbound legs resolve immediately; each gets
        // its own distinct token so the final state reveals which one
        // survived.
        let pairer = RemotePeerPairer(fetch: { req in
            let token = requests.seen.isEmpty ? "tokEarly" : "tokLate"
            requests.seen.append(req)
            return (Data(#"{"token":"\#(token)","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairer: pairer, links: Links(), reciprocalConfirmationTimeout: 0.05)
        manager.connectAll()

        async let early: RemotePeerManager.AddError? = manager.addPeer(link: linkFromA)
        while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        let earlyCounterCode = try #require((try body(of: requests.seen[0])["peer"] as? [String: Any])?["counterCode"] as? String)
        // Wait for EARLY's own upsert to have definitely completed before
        // starting LATE, so LATE's own `previousState` snapshot captures it.
        while manager.peers.first?.token != "tokEarly" { try? await Task.sleep(nanoseconds: 1_000_000) }

        async let late: RemotePeerManager.AddError? = manager.addPeer(link: linkFromA)
        // Wait for LATE's own upsert to have definitely completed too,
        // before delivering EARLY's confirmation.
        while manager.peers.first?.token != "tokLate" { try? await Task.sleep(nanoseconds: 1_000_000) }

        // Confirm ONLY EARLY's own counter-code — LATE's own is never
        // confirmed and will time out.
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: nil,
            localDeviceId: "early-confirmed-device", redeemedCode: earlyCounterCode))

        let earlyResult = await early
        let lateResult = await late
        #expect(earlyResult == nil)
        #expect(lateResult == .reciprocalPairingFailed)

        let peer = try #require(manager.peers.first)
        // EARLY's own state — the one that actually got confirmed —
        // survives LATE's rollback...
        #expect(peer.token == "tokEarly")
        // ...along with EARLY's own just-arrived confirmation, rather than
        // LATE's rollback reverting it back to the pre-existing device.
        #expect(peer.localDeviceId == "early-confirmed-device")
    }

    // Two overlapping outbound adds for the same, already-paired identity,
    // where NEITHER attempt's own reciprocal call is ever confirmed. LATE's
    // own `previousState` must not be EARLY's own dead provisional row —
    // itself just as unconfirmed as LATE's — or LATE's rollback would
    // persist a peer holding a token nobody ever validated. It must reach
    // all the way back to the last genuinely durable relationship instead.
    @Test func addPeerDoubleFailureRestoresTheLastDurableStateNotADeadSiblingSnapshot() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "old-device", addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        let pairer = RemotePeerPairer(fetch: { req in
            let token = requests.seen.isEmpty ? "tokEarly" : "tokLate"
            requests.seen.append(req)
            return (Data(#"{"token":"\#(token)","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(store: store, pairer: pairer, links: Links(), reciprocalConfirmationTimeout: 0.05)
        manager.connectAll()

        async let early: RemotePeerManager.AddError? = manager.addPeer(link: linkFromA)
        while requests.seen.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        while manager.peers.first?.token != "tokEarly" { try? await Task.sleep(nanoseconds: 1_000_000) }

        async let late: RemotePeerManager.AddError? = manager.addPeer(link: linkFromA)
        while manager.peers.first?.token != "tokLate" { try? await Task.sleep(nanoseconds: 1_000_000) }

        // Neither attempt's own counter-code is ever confirmed — both time out.
        let earlyResult = await early
        let lateResult = await late
        #expect(earlyResult == .reciprocalPairingFailed)
        #expect(lateResult == .reciprocalPairingFailed)

        let peer = try #require(manager.peers.first)
        #expect(peer.token == "old-token")
        #expect(peer.localDeviceId == "old-device")
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

    // `request.origins` is attacker-controlled. A request claiming identity
    // X but pointing this pair-back at an endpoint that answers as Y must
    // not have Y's token persisted under X — that would misdirect every
    // future connection to X toward Y instead.
    @Test func handleInboundPeerRejectsAPairBackReplyClaimingADifferentIdentity() async throws {
        let requests = Requests()
        var revoked: [String] = []
        let manager = makeManager(pairer: pairer(["10.0.0.9:8765": (200, #"{"token":"tokY","serverId":"srv-y","name":"Mac Y"}"#)], requests: requests), links: Links())
        manager.onRevokeDevice = { revoked.append($0) }
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-x", peerName: "Mac X", origins: ["http://10.0.0.9:8765"], counterCode: "CC",
            localDeviceId: "dev-x", redeemedCode: "ABC123"))
        #expect(manager.peers.isEmpty)
        #expect(revoked.contains("dev-x"))
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

    // addPeer cannot snapshot a per-identity generation before its own
    // network round trip the way handleInboundPeer can — it does not learn
    // which identity it is even talking to until the reply names it. A
    // peer created by a completely unrelated, CONCURRENT inbound pairing
    // for that same identity — one this attempt could never have known
    // about in advance — must still not be resurrected if the user forgets
    // it while this attempt's own round trip is still in flight.
    @Test func addPeerDoesNotResurrectAPeerForgottenFromAConcurrentInboundPairing() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        // Delays only addPeer's own outbound leg (redeeming "ABC123", from
        // linkFromA) — the concurrent inbound pairing's own reciprocal leg
        // (redeeming "CC") resolves immediately, so it and its Forget both
        // land well before addPeer's own reply comes back.
        let pairer = RemotePeerPairer(fetch: { req in
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if (body?["code"] as? String) == "ABC123" {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            return (Data(#"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(pairing: pairing, pairer: pairer, links: Links())
        manager.connectAll()
        Task {
            guard let inbound = try? pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a") else { return }
            await manager.handleInboundPeer(RemotePeerPairingRequest(
                peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"], counterCode: "CC",
                localDeviceId: inbound.deviceId, redeemedCode: "XYZ"))
            guard let peer = manager.peers.first(where: { $0.serverId == "srv-a" }) else { return }
            manager.forget(peerId: peer.id)
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

    // The forgotten-during-pair-back check above still has a gap: it only
    // snapshots identities at the START of handleInboundPeer's own body,
    // but that body is itself scheduled via onPeerPaired's
    // Task { @MainActor in ... } hop, an arbitrary delay after the /pair
    // redemption that triggered it. A Forget landing in THAT gap is already
    // gone by the time handleInboundPeer's own snapshot runs, so it would
    // never be recognized as "existed before" at all.
    // notePeerPairingArrived captures that fact synchronously, at redemption
    // time, closing the gap.
    @Test func aPeerForgottenBetweenRedemptionAndHandleInboundPeerStartingIsNotResurrected() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let inbound = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-b", name: "old", origins: ["http://10.0.0.2:8765"],
                               lastOrigin: "http://10.0.0.2:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-b", addedAt: Date(timeIntervalSince1970: 1))])
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer(["10.0.0.2:8765": (200, #"{"token":"tokB","serverId":"srv-b","name":"Mac B"}"#)], requests: Requests()),
                                  links: Links())
        manager.connectAll()
        // Simulates the exact moment redemption fires, synchronously —
        // followed immediately by a Forget landing in the scheduling gap
        // before handleInboundPeer's own body ever starts.
        manager.notePeerPairingArrived(serverId: "srv-b", localDeviceId: inbound.deviceId)
        manager.forget(peerId: "p1")
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "CC",
            localDeviceId: inbound.deviceId, redeemedCode: "ABC123"))
        #expect(manager.peers.isEmpty)
        #expect(pairing.validate(token: inbound.token) == nil)
    }

    // startGenerationAtRedeem must be keyed per-redemption, not per-identity:
    // two redemptions for the SAME identity landing close together would
    // otherwise share one slot, and the later one overwriting the earlier
    // one's snapshot would make the earlier redemption's handler compare
    // against the WRONG baseline once it finally runs.
    @Test func concurrentRedemptionsForTheSameIdentityDoNotClobberEachOthersGenerationSnapshot() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-b", name: "old", origins: ["http://10.0.0.2:8765"],
                               lastOrigin: "http://10.0.0.2:8765", token: "old-token", protocolVersion: 1,
                               localDeviceId: "dev-old", addedAt: Date(timeIntervalSince1970: 1))])
        let deviceA = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: pairer(["10.0.0.2:8765": (200, #"{"token":"tokB","serverId":"srv-b","name":"Mac B"}"#)], requests: Requests()),
                                  links: Links())
        manager.connectAll()
        // Redemption A arrives first and captures the current generation (0).
        manager.notePeerPairingArrived(serverId: "srv-b", localDeviceId: deviceA.deviceId)
        // The user forgets the existing peer, bumping the generation to 1.
        manager.forget(peerId: "p1")
        // A second, unrelated redemption for the SAME identity captures its
        // OWN (now-current) generation (1) — this must not clobber A's
        // earlier snapshot.
        let deviceB = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        manager.notePeerPairingArrived(serverId: "srv-b", localDeviceId: deviceB.deviceId)
        // A's handler finally runs — it must still see its OWN true
        // starting generation (0), not B's (1), and therefore detect the
        // change and reject rather than resurrect the forgotten peer.
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "CCA",
            localDeviceId: deviceA.deviceId, redeemedCode: "CODE-A"))
        #expect(manager.peers.isEmpty)
        #expect(pairing.validate(token: deviceA.token) == nil)
    }

    // Two concurrent reciprocal exchanges for the SAME, previously-unknown
    // identity — e.g. a retried pair-back — can each observe "nothing
    // exists yet" at their own start, since neither has upserted anything
    // yet. A before/after existence check alone would never catch the
    // second one resurrecting a peer the FIRST one's own success let the
    // user forget, because the second never itself observed the peer
    // existing — only the shared forget-generation, bumped regardless of
    // which sibling's row is being forgotten, can catch this.
    @Test func aConcurrentSiblingExchangeDoesNotResurrectAPeerForgottenByTheOther() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let device1 = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        let device2 = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac B", peerServerId: "srv-b")
        // The request redeeming "CC1" resolves quickly; the one redeeming
        // "CC2" resolves later, after the first has already upserted and
        // been forgotten. Keyed by the request body — not by arrival order
        // at this closure — so the outcome does not depend on how the two
        // concurrent calls happen to get scheduled.
        let pairer = RemotePeerPairer(fetch: { req in
            let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let isFirst = (body?["code"] as? String) == "CC1"
            try? await Task.sleep(nanoseconds: (isFirst ? 5 : 40) * 1_000_000)
            return (Data(#"{"token":"tok","serverId":"srv-b","name":"Mac B"}"#.utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
        let manager = makeManager(pairing: pairing, pairer: pairer, links: Links())
        manager.connectAll()

        async let first: Void = manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "CC1",
            localDeviceId: device1.deviceId, redeemedCode: "CODE1"))
        async let second: Void = manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "CC2",
            localDeviceId: device2.deviceId, redeemedCode: "CODE2"))
        _ = await first
        let peer = try #require(manager.peers.first)
        #expect(peer.localDeviceId == device1.deviceId)
        manager.forget(peerId: peer.id)
        _ = await second

        #expect(manager.peers.isEmpty)
        #expect(pairing.validate(token: device2.token) == nil)
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

    // `.hello`/`.originChanged` update `peers` directly on an already
    // confirmed link, bypassing `upsert` entirely. If the durable snapshot
    // `addPeer` rolls back to on a later failed re-pair isn't refreshed the
    // same way, that rollback would revert the name/protocol version/origin
    // a working connection already updated — potentially preferring a dead
    // origin again over the one just proven to work.
    @Test func linkEventsKeepTheDurableSnapshotInSyncSoALaterFailedRepairDoesNotRevertThem() async throws {
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "old", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", protocolVersion: nil,
                               localDeviceId: "old-device", addedAt: Date(timeIntervalSince1970: 1))])
        let links = Links()
        let requests = Requests()
        let manager = makeManager(store: store,
                                  pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokNew","serverId":"srv-a","name":"Mac A"}"#)], requests: requests),
                                  links: links, reciprocalConfirmationTimeout: 0.02)
        manager.connectAll()
        let link = try #require(links.byPeerId["p1"])
        link.emit(.hello(serverId: "srv-a", name: "Mac A (renamed)", protocolVersion: 2, federationEnabled: true))
        link.emit(.originChanged("http://10.0.0.9:8765"))

        // A re-pair attempt starts, its own reciprocal call is never
        // confirmed, and it rolls back.
        let error = await manager.addPeer(link: linkFromA)
        #expect(error == .reciprocalPairingFailed)

        let peer = try #require(manager.peers.first)
        #expect(peer.token == "old-token")
        #expect(peer.localDeviceId == "old-device")
        // Restored to the pre-attempt relationship, but with the metadata
        // a working connection already updated — not the stale snapshot
        // from before those link events.
        #expect(peer.name == "Mac A (renamed)")
        #expect(peer.protocolVersion == 2)
        #expect(peer.lastOrigin == "http://10.0.0.9:8765")
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

    // MARK: identity binding

    /// A pairer whose replies prove possession of `key` under `serverId` —
    /// what a real peer running this build produces.
    private func provingPairer(serverId: String, key: Curve25519.Signing.PrivateKey,
                               token: String = "tokA", name: String = "Mac A",
                               requests: Requests) -> RemotePeerPairer {
        RemotePeerPairer(fetch: { req in
            requests.seen.append(req)
            let payload = try #require(req.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            let challenge = try #require(object["challenge"] as? String)
            let proof = try #require(RemoteIdentityCrypto.sign(serverId: serverId, challenge: challenge, with: key))
            let reply = """
                {"token":"\(token)","serverId":"\(serverId)","name":"\(name)",\
                "publicKey":"\(proof.publicKey)","signature":"\(proof.signature)"}
                """
            return (Data(reply.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, timeout: 1)
    }

    @Test func addPeerPinsTheProvedKeyOnTheRecord() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let requests = Requests()
        let store = InMemoryPeerStore()
        let manager = makeManager(store: store,
                                  pairer: provingPairer(serverId: "srv-a", key: key, requests: requests),
                                  links: Links())
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        let peer = try #require(manager.peers.first)
        #expect(peer.publicKey == RemoteIdentityCrypto.publicKeyString(key.publicKey))
        #expect(peer.isVerified)
        #expect(store.saved.first?.publicKey == peer.publicKey)
    }

    // The advertisement has to carry this Mac's own key, or the far side has
    // nothing to pin us to and its record stays unverified forever.
    @Test func theAdvertisementCarriesThisMacsPublicKey() async throws {
        let requests = Requests()
        let manager = makeManager(
            pairer: provingPairer(serverId: "srv-a", key: Curve25519.Signing.PrivateKey(), requests: requests),
            links: Links(),
            identity: RemotePeerManager.LocalIdentity(serverId: "srv-b", name: "Mac B",
                                                      origins: ["http://10.0.0.2:8765"], publicKey: "my-key"))
        _ = await manager.addPeer(link: linkFromA)
        let first = try #require(requests.seen.first)
        let advertised = try #require(body(of: first)["peer"] as? [String: Any])
        #expect(advertised["publicKey"] as? String == "my-key")
    }

    // THE issue's central case, at the manager level: an established peer's
    // record is pinned to its key, and another exchange claiming the same
    // `serverId` with different key material must not re-key it or redirect
    // its outbound link — no matter that it holds a live pairing code.
    @Test func anOutboundExchangeCannotRebindAPinnedRecordToAnotherKey() async throws {
        let realKey = Curve25519.Signing.PrivateKey()
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "real-token",
                               publicKey: RemoteIdentityCrypto.publicKeyString(realKey.publicKey),
                               protocolVersion: 1, localDeviceId: "real-device",
                               addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        // The claimant proves a key of its own — it genuinely holds one —
        // but it is not the key this record was paired with.
        let manager = makeManager(store: store,
                                  pairer: provingPairer(serverId: "srv-a", key: Curve25519.Signing.PrivateKey(),
                                                        token: "claimant-token", name: "Impostor",
                                                        requests: requests),
                                  links: Links())
        #expect(await manager.addPeer(link: linkFromA) == .identityRebindRefused)
        let peer = try #require(manager.peers.first)
        #expect(peer.token == "real-token")
        #expect(peer.name == "Mac A")
        #expect(peer.publicKey == RemoteIdentityCrypto.publicKeyString(realKey.publicKey))
    }

    // Same refusal from the inbound direction — the shape the impersonation
    // actually takes: the claimant redeems a code HERE while advertising the
    // established peer's identity. The device it minted must not survive.
    @Test func anInboundRedeemCannotRebindAPinnedRecordToAnotherKey() async throws {
        let realKey = Curve25519.Signing.PrivateKey()
        let pinned = RemoteIdentityCrypto.publicKeyString(realKey.publicKey)
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "real-token", publicKey: pinned,
                               protocolVersion: 1, localDeviceId: "real-device",
                               addedAt: Date(timeIntervalSince1970: 1))])
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let claimantDevice = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Impostor",
                                                    peerServerId: "srv-a")
        let requests = Requests()
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: provingPairer(serverId: "srv-a", key: Curve25519.Signing.PrivateKey(),
                                                        requests: requests),
                                  links: Links())
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Impostor", origins: ["http://10.0.0.66:8765"],
            peerPublicKey: RemoteIdentityCrypto.publicKeyString(Curve25519.Signing.PrivateKey().publicKey),
            counterCode: "CTR", localDeviceId: claimantDevice.deviceId, redeemedCode: "CODE"))
        let peer = try #require(manager.peers.first)
        #expect(peer.token == "real-token")
        #expect(peer.origins == ["http://10.0.0.1:8765"])
        #expect(peer.publicKey == pinned)
        // The inbound grant is taken back too, so the claimant keeps no
        // access on this Mac either.
        #expect(!pairing.devices.contains { $0.id == claimantDevice.deviceId })
        // Refused before any pair-back was dialed: no code is spent on it.
        #expect(requests.seen.isEmpty)
    }

    // A request that advertises one key while its own endpoint proves a
    // different one is refused rather than reconciled toward either.
    @Test func anInboundRequestWhoseEndpointProvesADifferentKeyIsRefused() async throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let device = try pairing.redeemPeer(code: pairing.beginPairing(), deviceName: "Mac A", peerServerId: "srv-a")
        let store = InMemoryPeerStore()
        let manager = makeManager(store: store, pairing: pairing,
                                  pairer: provingPairer(serverId: "srv-a", key: Curve25519.Signing.PrivateKey(),
                                                        requests: Requests()),
                                  links: Links())
        await manager.handleInboundPeer(RemotePeerPairingRequest(
            peerServerId: "srv-a", peerName: "Mac A", origins: ["http://10.0.0.1:8765"],
            peerPublicKey: RemoteIdentityCrypto.publicKeyString(Curve25519.Signing.PrivateKey().publicKey),
            counterCode: "CTR", localDeviceId: device.deviceId, redeemedCode: "CODE"))
        #expect(manager.peers.isEmpty)
        #expect(!pairing.devices.contains { $0.id == device.deviceId })
    }

    // Re-pairing the SAME peer is the ordinary case and must keep working:
    // the key it proves is the one already pinned, so nothing is rebound.
    @Test func rePairingWithTheSameKeyIsAllowed() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let pinned = RemoteIdentityCrypto.publicKeyString(key.publicKey)
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", publicKey: pinned,
                               protocolVersion: 1, localDeviceId: "old-device",
                               addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        let manager = makeManager(store: store,
                                  pairer: provingPairer(serverId: "srv-a", key: key, token: "new-token",
                                                        requests: requests),
                                  links: Links())
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        #expect(manager.peers.first?.token == "new-token")
        #expect(manager.peers.first?.publicKey == pinned)
    }

    // A record paired before verification shipped has nothing pinned, so
    // re-pairing it is how the user upgrades it — the exchange they
    // initiated is what pins the key.
    @Test func rePairingAnUnverifiedRecordAdoptsTheProvedKey() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", publicKey: nil,
                               protocolVersion: 1, localDeviceId: "old-device",
                               addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        let manager = makeManager(store: store,
                                  pairer: provingPairer(serverId: "srv-a", key: key, token: "new-token",
                                                        requests: requests),
                                  links: Links())
        confirmReciprocalPairing(on: manager, requests: requests, peerServerId: "srv-a")
        #expect(await manager.addPeer(link: linkFromA) == nil)
        #expect(manager.peers.first?.publicKey == RemoteIdentityCrypto.publicKeyString(key.publicKey))
        #expect(manager.peers.first?.isVerified == true)
    }

    // A peer that stops advertising a key cannot drop an established
    // binding: only the user's own Forget can.
    @Test func aPeerCannotUnpinItselfByOfferingNoKey() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let pinned = RemoteIdentityCrypto.publicKeyString(key.publicKey)
        let store = InMemoryPeerStore()
        store.save([RemotePeer(id: "p1", serverId: "srv-a", name: "Mac A", origins: ["http://10.0.0.1:8765"],
                               lastOrigin: "http://10.0.0.1:8765", token: "old-token", publicKey: pinned,
                               protocolVersion: 1, localDeviceId: "old-device",
                               addedAt: Date(timeIntervalSince1970: 1))])
        let requests = Requests()
        // A reply with no key at all — an older build, or something
        // pretending to be one.
        let manager = makeManager(
            store: store,
            pairer: pairer(["10.0.0.1:8765": (200, #"{"token":"tokA","serverId":"srv-a","name":"Mac A"}"#)],
                           requests: requests),
            links: Links())
        #expect(await manager.addPeer(link: linkFromA) == .identityRebindRefused)
        #expect(manager.peers.first?.publicKey == pinned)
        #expect(manager.peers.first?.token == "old-token")
    }

    // Phase 3 must not carry sessions over a link nobody proved anything to
    // open. An unverified record still connects; it just does not qualify.
    @Test func onlyAVerifiedOnlinePeerCarriesSessions() async throws {
        let store = InMemoryPeerStore()
        store.save([
            RemotePeer(id: "p1", serverId: "srv-a", name: "Verified", origins: ["http://10.0.0.1:8765"],
                       lastOrigin: nil, token: "t", publicKey: "a-key", addedAt: Date()),
            RemotePeer(id: "p2", serverId: "srv-b", name: "Legacy", origins: ["http://10.0.0.2:8765"],
                       lastOrigin: nil, token: "t", publicKey: nil, addedAt: Date()),
        ])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p2"]).emit(.stateChanged(.online))
        #expect(manager.carriesSessions(peerId: "p1"))
        #expect(!manager.carriesSessions(peerId: "p2"))
        // Not online is not enough either.
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.identityUnproven))
        #expect(!manager.carriesSessions(peerId: "p1"))
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

    private func verifiedPeer(id: String = "p1", serverId: String = "srv-a") -> RemotePeer {
        RemotePeer(id: id, serverId: serverId, name: "Mac A", origins: ["http://10.0.0.1:8765"], lastOrigin: nil,
                   token: "t", publicKey: "pinned-key", protocolVersion: nil, localDeviceId: nil, addedAt: Date())
    }

    private func unverifiedPeer(id: String = "p2", serverId: String = "srv-old") -> RemotePeer {
        RemotePeer(id: id, serverId: serverId, name: "Old Mac", origins: ["http://10.0.0.2:8765"], lastOrigin: nil,
                   token: "t", publicKey: nil, protocolVersion: nil, localDeviceId: nil, addedAt: Date())
    }

    @Test func sessionCarryingPeersListsOnlyVerifiedOnlineLinks() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer(), verifiedPeer(id: "p3", serverId: "srv-c")])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        #expect(manager.sessionCarryingPeers.isEmpty)
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p2"]).emit(.stateChanged(.online))   // unverified: never carries
        try #require(links.byPeerId["p3"]).emit(.stateChanged(.offline))
        #expect(manager.sessionCarryingPeers == [FederatedPeerInfo(serverId: "srv-a", name: "Mac A")])
    }

    @Test func peerFramesReachTheFederationEventOnlyOverACarryingLink() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer()])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        var events: [FederatedPeerLinkEvent] = []
        manager.onFederationEvent = { events.append($0) }
        manager.connectAll()
        let verified = try #require(links.byPeerId["p1"])
        let unverified = try #require(links.byPeerId["p2"])
        verified.emit(.message(.sessionClosed(sessionId: "x")))         // offline: dropped
        verified.emit(.stateChanged(.online))
        verified.emit(.message(.sessionClosed(sessionId: "x")))         // online + verified: forwarded
        unverified.emit(.stateChanged(.online))
        unverified.emit(.message(.sessionClosed(sessionId: "y")))       // online but unverified: dropped
        let forwarded = events.compactMap { event -> (String, RemoteServerMessage)? in
            if case .message(let serverId, let message) = event { return (serverId, message) }
            return nil
        }
        #expect(forwarded.count == 1)
        #expect(forwarded.first?.0 == "srv-a")
        #expect(forwarded.first?.1 == .sessionClosed(sessionId: "x"))
        let availability = events.compactMap { event -> String? in
            if case .availabilityChanged(let serverId) = event { return serverId }
            return nil
        }
        #expect(availability.contains("srv-a"))
        #expect(availability.contains("srv-old"))
    }

    @Test func sendToPeerOnlyReachesACarryingLink() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer()])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        let verified = try #require(links.byPeerId["p1"])
        let unverified = try #require(links.byPeerId["p2"])
        manager.sendToPeer(.listSessions, serverId: "srv-a")            // offline: dropped
        verified.emit(.stateChanged(.online))
        unverified.emit(.stateChanged(.online))
        manager.sendToPeer(.listSessions, serverId: "srv-a")
        manager.sendToPeer(.listSessions, serverId: "srv-old")
        manager.sendToPeer(.listSessions, serverId: "srv-nobody")
        #expect(verified.sent == [.listSessions])
        #expect(unverified.sent.isEmpty)
    }

    @Test func helloPeersReportEveryRecordWithItsLinkState() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), unverifiedPeer(), verifiedPeer(id: "p3", serverId: "srv-c")])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p2"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p3"]).emit(.stateChanged(.identityUnproven))
        #expect(manager.helloPeers == [
            RemoteHelloPeer(serverId: "srv-a", name: "Mac A", state: "online"),
            RemoteHelloPeer(serverId: "srv-old", name: "Old Mac", state: "unverified"),
            RemoteHelloPeer(serverId: "srv-c", name: "Mac A", state: "identityUnproven"),
        ])
    }

    @Test func forgetAndDisconnectAllAnnounceAvailabilityChanges() throws {
        let store = InMemoryPeerStore()
        store.save([verifiedPeer(), verifiedPeer(id: "p3", serverId: "srv-c")])
        let links = Links()
        let manager = makeManager(store: store, pairer: pairer([:], requests: Requests()), links: links)
        manager.connectAll()
        try #require(links.byPeerId["p1"]).emit(.stateChanged(.online))
        try #require(links.byPeerId["p3"]).emit(.stateChanged(.online))
        var announced: [String] = []
        manager.onFederationEvent = { if case .availabilityChanged(let id) = $0 { announced.append(id) } }
        manager.forget(peerId: "p1")
        #expect(announced == ["srv-a"])
        #expect(manager.sessionCarryingPeers == [FederatedPeerInfo(serverId: "srv-c", name: "Mac A")])
        manager.disconnectAll()
        #expect(announced.contains("srv-c"))
        #expect(manager.sessionCarryingPeers.isEmpty)
    }
}
