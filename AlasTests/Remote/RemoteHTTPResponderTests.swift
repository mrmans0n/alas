import Testing
import Foundation
import CryptoKit
@testable import Alas

@MainActor
struct RemoteHTTPResponderTests {
    private let privateOrigin = "http://192.168.1.20:8765"

    private func makeResponder(pairing: RemotePairingService = RemotePairingService(store: InMemoryDeviceStore())) -> RemoteHTTPResponder {
        RemoteHTTPResponder(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: {
                RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true, pairedDeviceCount: 0)
            },
            originPolicy: RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])
        )
    }

    private func request(_ method: String, _ path: String, origin: String? = nil) -> HTTPRequest {
        var headers = ["host": "127.0.0.1"]
        if let origin { headers["origin"] = origin }
        return HTTPRequest(method: method, path: path, query: [:], headers: headers)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    @Test func nativeApprovalRoutesDefaultToForbiddenWithoutCORS() {
        for origin in [nil, "", "null", privateOrigin] as [String?] {
            let out = text(makeResponder().response(for: request("POST", "/peer-approval/v1/challenge", origin: origin), body: Data()))
            #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
            #expect(!out.contains("Access-Control-"))
        }
    }

    @Test func diagnosticsWithoutApprovalCapabilityRemainDecodable() throws {
        let body = Data(#"{"appName":"Alas","addresses":[],"usesPlainHTTP":true,"pairedDeviceCount":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(RemoteDiagnosticsSnapshot.self, from: body)
        #expect(snapshot.pairingApprovalVersion == nil)
        #expect(snapshot.serverId == nil)
    }

    @Test func healthCarriesCORSHeadersForAnAllowedOrigin() {
        let out = text(makeResponder().response(for: request("GET", "/health", origin: privateOrigin), body: Data()))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
        #expect(out.contains("Vary: Origin\r\n"))
    }

    // Regression: the health probe used to treat
    // any 2xx as proof of talking to the paired Mac, so a DHCP-reused
    // address or a coincidental unrelated Alas instance could falsely mark
    // a genuinely offline paired Mac as revoked. /health now includes the
    // server's own identity so the client can verify it before trusting it.
    @Test func healthIncludesServerIdWhenKnown() {
        let responder = RemoteHTTPResponder(
            pairing: RemotePairingService(store: InMemoryDeviceStore()),
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: {
                RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true, pairedDeviceCount: 0, serverId: "srv-1")
            },
            originPolicy: RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])
        )
        let out = text(responder.response(for: request("GET", "/health"), body: Data()))
        #expect(out.contains(#""serverId":"srv-1""#))
    }

    @Test func healthOmitsServerIdWhenUnknown() {
        let out = text(makeResponder().response(for: request("GET", "/health"), body: Data()))
        #expect(!out.contains("serverId"))
    }

    @Test func healthWithoutOriginHasNoCORSHeaders() {
        let out = text(makeResponder().response(for: request("GET", "/health"), body: Data()))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!out.contains("Access-Control-Allow-Origin"))
    }

    // The connection layer rejects disallowed origins before the responder
    // runs; the responder must still never echo one back.
    @Test func healthWithDisallowedOriginNeverEchoesIt() {
        let out = text(makeResponder().response(for: request("GET", "/health", origin: "https://evil.example"), body: Data()))
        #expect(!out.contains("Access-Control-Allow-Origin"))
    }

    @Test func optionsPairPreflightAnswers204WithAllowances() {
        let out = text(makeResponder().response(for: request("OPTIONS", "/pair", origin: privateOrigin), body: Data()))
        #expect(out.hasPrefix("HTTP/1.1 204 No Content"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
        #expect(out.contains("Access-Control-Allow-Methods: POST, OPTIONS\r\n"))
        #expect(out.contains("Access-Control-Allow-Headers: content-type\r\n"))
        #expect(out.contains("Access-Control-Max-Age: 600\r\n"))
    }

    @Test func pairResponseCarriesCORSHeaders() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
        let out = text(makeResponder(pairing: pairing).response(for: request("POST", "/pair", origin: privateOrigin), body: body))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
        #expect(out.contains(#""token":"#))
    }

    @Test func failedPairStillCarriesCORSHeaders() {
        let out = text(makeResponder().response(for: request("POST", "/pair", origin: privateOrigin), body: Data(#"{"code":"NOPE","deviceName":"x"}"#.utf8)))
        #expect(out.hasPrefix("HTTP/1.1 401 Unauthorized"))
        #expect(out.contains("Access-Control-Allow-Origin: \(privateOrigin)\r\n"))
    }

    @Test func extraHeadersLandInsideTheHeaderBlock() {
        let out = text(RemoteHTTPResponder.http(status: "200 OK", contentType: "text/plain", body: Data("x".utf8), extraHeaders: [("X-Test", "1")]))
        let headerBlock = out.components(separatedBy: "\r\n\r\n")[0]
        #expect(headerBlock.contains("X-Test: 1"))
        #expect(out.hasSuffix("\r\n\r\nx"))
    }

    private final class PeerSink {
        var requests: [RemotePeerPairingRequest] = []
    }

    private func makePeerResponder(pairing: RemotePairingService, accepts: Bool, sink: PeerSink,
                                   signingKey: Curve25519.Signing.PrivateKey? = nil) -> RemoteHTTPResponder {
        var responder = RemoteHTTPResponder(
            pairing: pairing,
            assets: RemoteWebAssets(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            diagnostics: {
                RemoteDiagnosticsSnapshot(appName: "Alas", port: 1, addresses: [], usesPlainHTTP: true, pairedDeviceCount: 0)
            },
            originPolicy: RemoteOriginPolicy(hostPolicy: .loopback, allowedOrigins: [])
        )
        responder.acceptsPeers = { accepts }
        responder.onPeerPaired = { sink.requests.append($0) }
        responder.identity = { RemoteServerIdentity(serverId: "srv-a", name: "Mac A", hubEnabled: false) }
        if let signingKey {
            responder.identityProof = { challenge in
                RemoteIdentityCrypto.sign(serverId: "srv-a", challenge: challenge, with: signingKey)
            }
        }
        return responder
    }

    /// The `/pair` reply is where a record's key binding is committed to, so
    /// the key must arrive WITH a signature over the caller's own challenge.
    /// A key alone is public information and would prove nothing.
    @Test func pairReplySignsTheCallersChallenge() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let challenge = RemoteIdentityCrypto.randomChallenge()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","challenge":"\#(challenge)"}"#.utf8)
        let out = makePeerResponder(pairing: pairing, accepts: true, sink: PeerSink(), signingKey: key)
            .response(for: request("POST", "/pair"), body: body)
        let json = try #require(String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let publicKey = try #require(object["publicKey"] as? String)
        let signature = try #require(object["signature"] as? String)
        #expect(publicKey == RemoteIdentityCrypto.publicKeyString(key.publicKey))
        #expect(RemoteIdentityCrypto.verify(
            RemoteIdentityProof(challenge: challenge, publicKey: publicKey, signature: signature),
            serverId: "srv-a", expectedPublicKey: publicKey, challenge: challenge))
    }

    // Nothing to sign means nothing signed: a reply carrying a signature
    // over anything but the caller's own challenge would only invite a
    // caller to accept it as proof of something it is not.
    @Test func pairReplyOmitsTheProofWhenNoChallengeWasSent() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
        let out = makePeerResponder(pairing: pairing, accepts: true, sink: PeerSink(),
                                    signingKey: Curve25519.Signing.PrivateKey())
            .response(for: request("POST", "/pair"), body: body)
        let json = try #require(String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["publicKey"] == nil)
        #expect(object["signature"] == nil)
    }

    // A build with no identity key pairs without one rather than inventing
    // something: the far side's record is then unverified, not wrongly bound.
    @Test func pairReplyOmitsTheProofWhenThisMacHasNoKey() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","challenge":"abc"}"#.utf8)
        let out = makePeerResponder(pairing: pairing, accepts: true, sink: PeerSink())
            .response(for: request("POST", "/pair"), body: body)
        let json = try #require(String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["publicKey"] == nil)
    }

    // An advertised key that could never be verified is refused while the
    // code is still unconsumed, rather than stored as an unusable string.
    @Test func pairWithAMalformedPublicKeyIsRejectedAndLeavesTheCodeRedeemable() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":["http://a:1"],"publicKey":"not-a-key"}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: PeerSink())
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    // The advertised key has to reach the app, or the inbound side has
    // nothing to cross-check its own pair-back against.
    @Test func theAdvertisedKeyIsHandedToTheApp() throws {
        let key = RemoteIdentityCrypto.publicKeyString(Curve25519.Signing.PrivateKey().publicKey)
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":["http://a:1"],"counterCode":"C0DE","publicKey":"\#(key)"}}"#.utf8)
        _ = makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body)
        #expect(sink.requests.first?.peerPublicKey == key)
    }

    @Test func pairReplyCarriesServerIdentity() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"phone"}"#.utf8)
        let out = makePeerResponder(pairing: pairing, accepts: false, sink: PeerSink())
            .response(for: request("POST", "/pair"), body: body)
        let json = try #require(String(decoding: out, as: UTF8.self).components(separatedBy: "\r\n\r\n").last)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect((object["token"] as? String)?.isEmpty == false)
        #expect(object["serverId"] as? String == "srv-a")
        #expect(object["name"] as? String == "Mac A")
    }

    @Test func pairWithPeerCreatesAnInstanceDeviceAndNotifies() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"""
        {"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":["http://100.64.1.9:8765"],"counterCode":"C0DE"}}
        """#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        let device = try #require(pairing.devices.first)
        #expect(device.kind == .alasInstance)
        #expect(device.peerServerId == "srv-b")
        #expect(sink.requests == [RemotePeerPairingRequest(
            peerServerId: "srv-b", peerName: "Mac B", origins: ["http://100.64.1.9:8765"],
            counterCode: "C0DE", localDeviceId: device.id, redeemedCode: code)])
    }

    @Test func pairWithPeerIsForbiddenWhenFederationIsOff() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":[]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: false, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect(sink.requests.isEmpty)
        // The code was not consumed: a plain browser pair with it still works.
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    // One valid code must not buy a sequential probe of arbitrary host:port
    // pairs from inside this network: the pair-back walks every advertised
    // origin with a POST, so the list is bounded before the code is redeemed.
    @Test func pairWithTooManyOriginsIsRejectedAndLeavesTheCodeRedeemable() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let origins = (1...9).map { #""http://10.0.0.\#($0):8765""# }.joined(separator: ",")
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":[\#(origins)]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect(sink.requests.isEmpty)
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    // An empty identity would collapse every peer onto one record. The
    // initiator path already refuses it; the responder path must too.
    @Test func pairWithEmptyPeerServerIdIsRejectedAndLeavesTheCodeRedeemable() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"","name":"Mac B","origins":["http://10.0.0.1:8765"]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect(sink.requests.isEmpty)
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    @Test func pairWithAnOverlongPeerNameIsRejected() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let name = String(repeating: "a", count: 201)
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"\#(name)","origins":[]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    // Pasting this same Mac's own pairing link back at itself over a
    // reachable LAN or tailnet address would otherwise pass every other
    // check — the advertised serverId legitimately equals the local
    // identity's own — and persist an "online" peer that is actually just
    // this Mac.
    @Test func pairWithAPeerAdvertisingThisSameMacsOwnIdentityIsRejected() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac A","peer":{"serverId":"srv-a","name":"Mac A","origins":["http://10.0.0.1:8765"]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect(sink.requests.isEmpty)
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    @Test func pairWithAnOverlongDeviceNameIsRejected() {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let deviceName = String(repeating: "b", count: 201)
        let body = Data(#"{"code":"\#(code)","deviceName":"\#(deviceName)","peer":{"serverId":"srv-b","name":"Mac B","origins":[]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(pairing.devices.isEmpty)
        #expect((try? pairing.redeem(code: code, deviceName: "phone")) != nil)
    }

    // The generous bound still admits a realistic Mac.
    @Test func pairWithAHandfulOfOriginsStillPairs() throws {
        let pairing = RemotePairingService(store: InMemoryDeviceStore())
        let sink = PeerSink()
        let code = pairing.beginPairing()
        let origins = (1...8).map { #""http://10.0.0.\#($0):8765""# }.joined(separator: ",")
        let body = Data(#"{"code":"\#(code)","deviceName":"Mac B","peer":{"serverId":"srv-b","name":"Mac B","origins":[\#(origins)]}}"#.utf8)
        let out = text(makePeerResponder(pairing: pairing, accepts: true, sink: sink)
            .response(for: request("POST", "/pair"), body: body))
        #expect(out.hasPrefix("HTTP/1.1 200 OK"))
        #expect(sink.requests.first?.origins.count == 8)
    }
}
