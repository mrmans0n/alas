import CryptoKit
import Foundation
import Testing
@testable import Alas

@MainActor private final class HTTPSigner: ApprovalSigning {
    let key = Curve25519.Signing.PrivateKey()
    var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    func signApproval(_ payload: ApprovalPayload, reply: Bool) -> String? {
        try? key.signature(for: ApprovalWire.bytes(payload, reply: reply)).base64EncodedString()
    }
}

@MainActor private final class HTTPFixture {
    let signer = HTTPSigner()
    let caller = HTTPSigner()
    var enabled = true
    var time = Date(timeIntervalSince1970: 1000)
    func peer(_ signer: HTTPSigner, _ id: String) -> ApprovalPeer {
        ApprovalPeer(serverID: id, publicKey: signer.publicKey, name: id, origins: ["http://10.0.0.1:8765"])
    }
    lazy var coordinator: RemotePairingApprovalCoordinator = {
        let value = RemotePairingApprovalCoordinator(localPeer: { self.peer(self.signer, "receiver") },
                                                     signer: signer, now: { self.time })
        value.setEnabled(true)
        return value
    }()
    lazy var http = RemotePairingApprovalHTTP(coordinator: coordinator, enabled: { self.enabled })
    func response(_ route: String, body: Data = Data(), method: String = "POST", origin: String? = nil) -> String {
        let headers = origin.map { ["origin": $0] } ?? [:]
        let req = HTTPRequest(method: method, path: "/peer-approval/v1/" + route, query: [:], headers: headers)
        return String(decoding: http.response(for: req, body: body)!, as: UTF8.self)
    }
    func challenge() throws -> ApprovalEnvelope {
        let body = try JSONEncoder().encode(RemotePairingApprovalHTTP.ChallengeRequest(
            requester: peer(caller, "caller"), attemptNonce: String(repeating: "a", count: 64)))
        return try decode(response("challenge", body: body))
    }
    func request(_ reply: ApprovalEnvelope, _ operation: ApprovalOperation) -> ApprovalEnvelope {
        let p = reply.payload
        let payload = ApprovalPayload(operation: operation, requestID: p.requestID, requester: p.requester,
            receiver: p.receiver, attemptNonce: p.attemptNonce, operationNonce: String(repeating: "b", count: 64),
            challenge: p.challenge, expiresAtMilliseconds: p.expiresAtMilliseconds, phase: p.phase,
            counterCode: nil, responseDigest: nil)
        return ApprovalEnvelope(payload: payload, signature: caller.signApproval(payload, reply: false)!)
    }
    func decode(_ response: String) throws -> ApprovalEnvelope {
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!response.contains("Access-Control-"))
        return try JSONDecoder().decode(ApprovalEnvelope.self, from: Data(response.components(separatedBy: "\r\n\r\n").last!.utf8))
    }
}

@MainActor struct RemotePairingApprovalHTTPTests {
    @Test func approvedPairBindsAdvertisementCachesReplyAndKeepsDeviceProvisional() throws {
        let f = HTTPFixture()
        let pending = try f.coordinator.receive(f.request(f.challenge(), .submit))
        f.coordinator.decide(.allow, requestID: pending.payload.requestID)
        let approved = try f.coordinator.receive(f.request(pending, .status))
        let p = approved.payload
        let payload = ApprovalPayload(operation: .redeem, requestID: p.requestID, requester: p.requester,
            receiver: p.receiver, attemptNonce: p.attemptNonce, operationNonce: p.operationNonce,
            challenge: p.challenge, expiresAtMilliseconds: p.expiresAtMilliseconds, phase: p.phase,
            counterCode: "counter", responseDigest: nil)
        let envelope = ApprovalEnvelope(payload: payload, signature: f.caller.signApproval(payload, reply: false)!)
        struct Pair: Encodable { let deviceName: String; let peer: RemotePeerAdvertisement; let approval: ApprovalEnvelope }
        func body(code: String = "counter", origins: [String]? = nil) throws -> Data {
            try JSONEncoder().encode(Pair(deviceName: p.requester.name,
                peer: RemotePeerAdvertisement(serverId: p.requester.serverID, name: p.requester.name,
                    origins: origins ?? p.requester.origins, counterCode: code, publicKey: p.requester.publicKey), approval: envelope))
        }
        let store = InMemoryDeviceStore()
        let pairing = RemotePairingService(store: store)
        var responder = RemoteHTTPResponder(pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: { RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true, pairedDeviceCount: 0) })
        responder.acceptsPeers = { true }
        responder.approval = f.http
        var callbacks = 0
        responder.onApprovedPeerPaired = { _, _, _ in callbacks += 1 }
        func response(_ body: Data, origin: String? = nil) -> Data {
            responder.response(for: HTTPRequest(method: "POST", path: "/pair", query: [:],
                headers: origin.map { ["origin": $0] } ?? [:]), body: body)
        }
        #expect(String(decoding: try response(body(), origin: "null"), as: UTF8.self).contains("403 Forbidden"))
        #expect(String(decoding: try response(body(code: "changed")), as: UTF8.self).contains("401 Unauthorized"))
        #expect(String(decoding: try response(body(origins: ["http://10.0.0.9:8765"])), as: UTF8.self).contains("401 Unauthorized"))
        let first = try response(body())
        #expect(String(decoding: first, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
        #expect(try response(body()) == first)
        #expect(callbacks == 1)
        #expect(pairing.devices.count == 1)
        #expect(store.saved.isEmpty)
    }

    @Test(arguments: ["challenge", "submit", "status", "cancel"])
    func guardsRunBeforeDecoding(route: String) {
        let f = HTTPFixture()
        for origin in ["", "null", "http://127.0.0.1"] {
            let response = f.response(route, origin: origin)
            #expect(response.hasPrefix("HTTP/1.1 403 Forbidden"))
            #expect(!response.contains("Access-Control-"))
        }
        #expect(f.response(route, method: "OPTIONS").hasPrefix("HTTP/1.1 405"))
        #expect(f.response(route, body: Data(repeating: 32, count: 16 * 1024 + 1)).hasPrefix("HTTP/1.1 413"))
        #expect(f.response(route, body: Data("{".utf8)).hasPrefix("HTTP/1.1 400"))
        #expect(f.response(route, body: Data(repeating: 32, count: 16 * 1024)).hasPrefix("HTTP/1.1 400"))
        f.enabled = false
        #expect(f.response(route, method: "GET").hasPrefix("HTTP/1.1 403"))
        #expect(f.coordinator.entries.isEmpty)
    }

    @Test func routeMustMatchSignedOperation() throws {
        let f = HTTPFixture()
        let challenge = try f.challenge()
        let request = try JSONEncoder().encode(f.request(challenge, .cancel))
        #expect(f.response("submit", body: request).hasPrefix("HTTP/1.1 400"))
        #expect(f.coordinator.entries.first?.phase == .challenged)
    }

    @Test func signedTerminalStatusAndThrottling() throws {
        let f = HTTPFixture()
        let challenge = try f.challenge()
        let pending = try f.decode(f.response("submit", body: JSONEncoder().encode(f.request(challenge, .submit))))
        f.coordinator.decide(.decline, requestID: pending.payload.requestID)
        let terminal = try f.decode(f.response("status", body: JSONEncoder().encode(f.request(pending, .status))))
        #expect(terminal.payload.phase == .declined)
        #expect(ApprovalWire.verify(terminal, expectedKey: f.signer.publicKey, reply: true))
        let throttled = try f.response("status", body: JSONEncoder().encode(f.request(terminal, .status)))
        #expect(throttled.hasPrefix("HTTP/1.1 429"))
        #expect(throttled.contains("Retry-After: 2\r\n"))
    }

    @Test func authenticationConflictAndExpiry() throws {
        let f = HTTPFixture()
        let challenge = try f.challenge()
        let signed = f.request(challenge, .submit)
        let invalid = ApprovalEnvelope(payload: signed.payload, signature: "invalid")
        #expect(try f.response("submit", body: JSONEncoder().encode(invalid)).hasPrefix("HTTP/1.1 401"))
        _ = try f.decode(f.response("submit", body: JSONEncoder().encode(signed)))
        #expect(try f.response("cancel", body: JSONEncoder().encode(f.request(challenge, .cancel))).hasPrefix("HTTP/1.1 409"))
        let expired = HTTPFixture()
        let old = try expired.challenge()
        expired.time.addTimeInterval(30)
        #expect(try expired.response("submit", body: JSONEncoder().encode(expired.request(old, .submit))).hasPrefix("HTTP/1.1 410"))
    }

    @Test func unrelatedRoutesAreNotHandled() {
        let f = HTTPFixture()
        #expect(f.http.response(for: HTTPRequest(method: "POST", path: "/pair", query: [:], headers: [:]), body: Data()) == nil)
    }

    @Test func pendingCapacityReturnsConflictWithoutConsumingChallenge() throws {
        let f = HTTPFixture()
        for index in 0..<4 {
            let caller = HTTPSigner()
            let challenge = try f.coordinator.challenge(requester: f.peer(caller, "caller-\(index)"),
                attemptNonce: String(repeating: "a", count: 64))
            let payload = f.request(challenge, .submit).payload
            let envelope = ApprovalEnvelope(payload: payload, signature: caller.signApproval(payload, reply: false)!)
            let response = try f.response("submit", body: JSONEncoder().encode(envelope))
            #expect(response.hasPrefix(index < 3 ? "HTTP/1.1 200" : "HTTP/1.1 409"))
        }
        #expect(f.coordinator.entries.filter { $0.phase == .pending }.count == 3)
        #expect(f.coordinator.entries.filter { $0.phase == .challenged }.count == 1)
    }
}
