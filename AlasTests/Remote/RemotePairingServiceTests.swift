import Testing
import Foundation
@testable import Alas

/// In-memory `RemoteDeviceStore` for tests across the Remote suite. Lives in the
/// test target so it never ships in the production binary.
final class InMemoryDeviceStore: RemoteDeviceStore {
    private(set) var saved: [RemoteDevice] = []
    func load() -> [RemoteDevice] { saved }
    func save(_ devices: [RemoteDevice]) { saved = devices }
}

@MainActor
struct RemotePairingServiceTests {
    @Test func cancellingApprovedCounterCodeRevokesItsAlreadyRedeemedGrant() throws {
        let store = InMemoryDeviceStore()
        let service = RemotePairingService(store: store)
        let code = service.beginApprovedPairing()
        let grant = try service.redeemPeer(code: code, deviceName: "Peer", peerServerId: "peer")
        service.cancelCode(code)
        #expect(service.validate(token: grant.token) == nil)
        #expect(store.saved.isEmpty)
    }

    @Test func approvedCredentialsStayProvisionalAcrossOtherSaves() throws {
        let store = InMemoryDeviceStore()
        let service = RemotePairingService(store: store)
        let approved = service.issueApprovedPeer(deviceName: "Peer", peerServerId: "peer")
        #expect(service.validate(token: approved.token) == approved.deviceId)
        service.touch(deviceId: approved.deviceId)
        _ = try service.redeem(code: service.beginPairing(), deviceName: "Browser")
        #expect(RemotePairingService(store: store).validate(token: approved.token) == nil)
        service.commitApprovedPeer(deviceId: approved.deviceId)
        #expect(RemotePairingService(store: store).validate(token: approved.token) == approved.deviceId)
    }

    private func make() -> RemotePairingService {
        RemotePairingService(store: InMemoryDeviceStore(), now: { Date(timeIntervalSince1970: 1000) })
    }

    @Test func pairingCodeRoundTripIssuesToken() throws {
        let svc = make()
        let code = svc.beginPairing()
        let token = try svc.redeem(code: code, deviceName: "iPhone")
        #expect(!token.isEmpty)
        #expect(svc.validate(token: token) != nil)
        #expect(svc.devices.count == 1)
        #expect(svc.devices.first?.name == "iPhone")
    }

    @Test func codeIsSingleUse() throws {
        let svc = make()
        let code = svc.beginPairing()
        _ = try svc.redeem(code: code, deviceName: "A")
        #expect(throws: RemoteServerError.self) { _ = try svc.redeem(code: code, deviceName: "B") }
    }

    @Test func codeExpires() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let svc = RemotePairingService(store: InMemoryDeviceStore(), now: { clock })
        let code = svc.beginPairing()
        clock = Date(timeIntervalSince1970: 1000 + 121)  // > 120s TTL
        #expect(throws: RemoteServerError.self) { _ = try svc.redeem(code: code, deviceName: "X") }
    }

    @Test func tokenStoredHashedNotPlaintext() throws {
        let store = InMemoryDeviceStore()
        let svc = RemotePairingService(store: store, now: { Date(timeIntervalSince1970: 1000) })
        let code = svc.beginPairing()
        let token = try svc.redeem(code: code, deviceName: "iPhone")
        #expect(store.saved.first?.tokenHash != token)            // not the plaintext
        #expect(store.saved.first?.tokenHash.isEmpty == false)
    }

    @Test func revokeKillsToken() throws {
        let svc = make()
        let code = svc.beginPairing()
        let token = try svc.redeem(code: code, deviceName: "iPhone")
        let id = svc.devices.first!.id
        svc.revoke(deviceId: id)
        #expect(svc.validate(token: token) == nil)
        #expect(svc.devices.isEmpty)
    }

    @Test func revokeAllClearsEveryDevice() throws {
        let svc = make()
        _ = try svc.redeem(code: svc.beginPairing(), deviceName: "A")
        _ = try svc.redeem(code: svc.beginPairing(), deviceName: "B")
        #expect(svc.devices.count == 2)

        svc.revokeAll()

        #expect(svc.devices.isEmpty)
    }

    @Test func unknownTokenRejected() {
        let svc = make()
        #expect(svc.validate(token: "garbage") == nil)
    }

    @Test func touchUpdatesLastSeenAt() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let svc = RemotePairingService(store: InMemoryDeviceStore(), now: { clock })
        let code = svc.beginPairing()
        _ = try svc.redeem(code: code, deviceName: "iPad")
        let id = svc.devices.first!.id
        #expect(svc.devices.first?.lastSeenAt == nil)
        clock = Date(timeIntervalSince1970: 2000)
        svc.touch(deviceId: id)
        #expect(svc.devices.first?.lastSeenAt == Date(timeIntervalSince1970: 2000))
    }

    @Test func twoDevicesValidateIndependently() throws {
        let svc = make()
        let t1 = try svc.redeem(code: svc.beginPairing(), deviceName: "A")
        let t2 = try svc.redeem(code: svc.beginPairing(), deviceName: "B")
        let id1 = try #require(svc.validate(token: t1))
        let id2 = try #require(svc.validate(token: t2))
        #expect(id1 != id2)
        #expect(svc.validate(token: t1) == id1)  // still valid after a second device paired
    }

    @Test func lowercasedCodeStillRedeems() throws {
        let svc = make()
        let code = svc.beginPairing()
        // Hex codes are case-insensitive; a lowercased submission must still work.
        let token = try svc.redeem(code: code.lowercased(), deviceName: "iPhone")
        #expect(svc.validate(token: token) != nil)
    }

    @Test func tooManyFailedRedeemsAreThrottled() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let svc = RemotePairingService(store: InMemoryDeviceStore(), now: { clock })
        let code = svc.beginPairing()
        // 5 wrong-code attempts exhaust the window (a failed redeem keeps the code pending).
        for _ in 0..<5 {
            #expect(throws: RemoteServerError.self) { _ = try svc.redeem(code: "WRONGCODE", deviceName: "x") }
        }
        // The 6th attempt is throttled even with the CORRECT code.
        #expect(throws: RemoteServerError.self) { _ = try svc.redeem(code: code, deviceName: "x") }
        // Once the rate window passes (code TTL is longer), the correct code works again.
        clock = Date(timeIntervalSince1970: 1000 + 61)
        let token = try svc.redeem(code: code, deviceName: "x")
        #expect(svc.validate(token: token) != nil)
    }

    @Test func priorCodeStaysValidAfterRotation() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let svc = RemotePairingService(store: InMemoryDeviceStore(), now: { clock })
        let first = svc.beginPairing()
        clock = Date(timeIntervalSince1970: 1045)   // 45s later, still within the 120s TTL
        let second = svc.beginPairing()              // rotation mints a fresh code
        // The freshly-rotated code works...
        let t2 = try svc.redeem(code: second, deviceName: "B")
        #expect(svc.validate(token: t2) != nil)
        // ...and so does the prior code a device may have scanned just before rotation.
        let t1 = try svc.redeem(code: first, deviceName: "A")
        #expect(svc.validate(token: t1) != nil)
    }

    @Test func expiredPriorCodeIsPrunedOnRotation() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let svc = RemotePairingService(store: InMemoryDeviceStore(), now: { clock })
        let first = svc.beginPairing()
        clock = Date(timeIntervalSince1970: 1000 + 121)   // first code has now expired
        let second = svc.beginPairing()
        #expect(throws: RemoteServerError.self) { _ = try svc.redeem(code: first, deviceName: "X") }
        let t = try svc.redeem(code: second, deviceName: "Y")   // the fresh code still works
        #expect(svc.validate(token: t) != nil)
    }

    @Test func redeemPeerStoresKindAndServerId() throws {
        let svc = make()
        let result = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio", peerServerId: "srv-b")
        #expect(svc.validate(token: result.token) == result.deviceId)
        let device = try #require(svc.devices.first { $0.id == result.deviceId })
        #expect(device.kind == .alasInstance)
        #expect(device.peerServerId == "srv-b")
        #expect(device.name == "Studio")
    }

    // This used to assert the opposite — that a peer redeem evicted any
    // earlier record for the same `peerServerId`, invalidating its token.
    // A redeem only proves the caller holds a live pairing code; the
    // `peerServerId` beside it is an unverified claim. So the eviction was a
    // free way for one code holder to cut an established peer's access, and
    // the DoS was worth more to an attacker than the stale-token window was
    // to us. The property it protected — "no token issued to a peer outlives
    // the user forgetting that peer" — is now carried by
    // `RemotePeerManager.forget`, which revokes EVERY device matching the
    // identity, not just a remembered id
    // (`forgetRevokesEveryDeviceCarryingThePeersIdentity`). What is genuinely
    // weaker: between a re-pair and a forget, the superseded token stays
    // valid instead of dying at the moment of the re-pair. That token was
    // only ever issued to the real peer over an authenticated exchange, and
    // it is visible and individually revocable in Paired devices.
    @Test func redeemPeerKeepsEarlierRecordsForTheSameServer() throws {
        let svc = make()
        let first = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio", peerServerId: "srv-b")
        let second = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio (renamed)", peerServerId: "srv-b")
        #expect(svc.devices.filter { $0.peerServerId == "srv-b" }.count == 2)
        #expect(svc.validate(token: first.token) == first.deviceId)
        #expect(svc.validate(token: second.token) == second.deviceId)
    }

    @Test func redeemPeerDoesNotTouchBrowserDevices() throws {
        let svc = make()
        let phone = try svc.redeem(code: svc.beginPairing(), deviceName: "iPhone")
        _ = try svc.redeemPeer(code: svc.beginPairing(), deviceName: "Studio", peerServerId: "srv-b")
        #expect(svc.validate(token: phone) != nil)
        #expect(svc.devices.count == 2)
    }
}
