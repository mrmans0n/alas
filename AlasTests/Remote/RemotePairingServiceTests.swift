import Testing
import Foundation
@testable import Alas

@MainActor
struct RemotePairingServiceTests {
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

    @Test func unknownTokenRejected() {
        let svc = make()
        #expect(svc.validate(token: "garbage") == nil)
    }
}
