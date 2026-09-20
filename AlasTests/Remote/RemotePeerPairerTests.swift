import Testing
import Foundation
@testable import Alas

struct RemotePeerPairerTests {
    private final class Recorder {
        var requests: [URLRequest] = []
    }

    private func pairer(_ script: [String: (Int, String)], recorder: Recorder) -> RemotePeerPairer {
        RemotePeerPairer(fetch: { req in
            recorder.requests.append(req)
            let key = "\(req.url!.host!):\(req.url!.port!)"
            guard let (status, body) = script[key] else { throw URLError(.cannotConnectToHost) }
            let http = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), http)
        }, timeout: 1)
    }

    private let ad = RemotePeerAdvertisement(serverId: "srv-b", name: "Mac B", origins: ["http://10.0.0.2:8765"], counterCode: "C1")

    @Test func fallsThroughUnreachableOriginsAndReturnsTheAnsweringOne() async throws {
        let recorder = Recorder()
        let p = pairer(["10.0.0.9:8765": (200, #"{"token":"tok","serverId":"srv-a","name":"Mac A"}"#)], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .paired(token: "tok", serverId: "srv-a", name: "Mac A", origin: "http://10.0.0.9:8765"))
        #expect(recorder.requests.count == 2)
        let body = try #require(recorder.requests.last?.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["code"] as? String == "ABC")
        #expect(object["deviceName"] as? String == "Mac B")
        let peer = try #require(object["peer"] as? [String: Any])
        #expect(peer["serverId"] as? String == "srv-b")
        #expect(peer["counterCode"] as? String == "C1")
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func expiredCodeStopsAtTheFirstAnsweringOrigin() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.1:8765": (401, #"{"error":"pairing failed"}"#), "10.0.0.9:8765": (200, "{}")], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .expiredCode)
        #expect(recorder.requests.count == 1)
    }

    @Test func forbiddenIsOriginRejected() async {
        let p = pairer(["10.0.0.1:8765": (403, "{}")], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .originRejected)
    }

    @Test func nothingAnsweringIsUnreachable() async {
        let p = pairer([:], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.2:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .unreachable)
    }

    @Test func replyWithoutTokenIsSkipped() async {
        let p = pairer(["10.0.0.1:8765": (200, #"{"nope":true}"#)], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765"], code: "ABC", deviceName: "Mac B", advertisement: nil)
        #expect(outcome == .unreachable)
    }

    @Test func nonHTTPOriginsAreSkippedWithoutDialing() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.9:8765": (200, #"{"token":"tok","serverId":"srv-a","name":"Mac A"}"#)], recorder: recorder)
        let outcome = await p.pair(
            origins: ["file:///etc/passwd", "ftp://10.0.0.1:21", "http://10.0.0.9:8765"],
            code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .paired(token: "tok", serverId: "srv-a", name: "Mac A", origin: "http://10.0.0.9:8765"))
        // The two rejected origins must never have been dialed at all.
        #expect(recorder.requests.count == 1)
    }

    // The synthesized enum description would print the token verbatim, so any
    // future interpolation of an outcome would leak a live bearer token.
    @Test func pairedDescriptionRedactsTheToken() {
        let outcome = RemotePeerPairer.Outcome.paired(
            token: "s3cret-token", serverId: "srv-a", name: "Mac A", origin: "http://10.0.0.9:8765")
        let text = "\(outcome)"
        #expect(!text.contains("s3cret-token"))
        #expect(text.contains("<redacted>"))
        #expect(text.contains("srv-a"))
        #expect(text.contains("http://10.0.0.9:8765"))
        #expect("\(RemotePeerPairer.Outcome.expiredCode)" == "expiredCode")
    }
}
