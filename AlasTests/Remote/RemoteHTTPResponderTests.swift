import Testing
import Foundation
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

    private func makePeerResponder(pairing: RemotePairingService, accepts: Bool, sink: PeerSink) -> RemoteHTTPResponder {
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
        return responder
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
            counterCode: "C0DE", localDeviceId: device.id)])
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
}
