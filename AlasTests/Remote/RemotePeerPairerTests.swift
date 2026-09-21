import Testing
import Foundation
import Network
@testable import Alas

struct RemotePeerPairerTests {
    private final class Recorder {
        var requests: [URLRequest] = []
    }

    /// A raw TCP server that answers any request with a reply far larger
    /// than `RemotePeerPairer.maxReplyBytes`, closing the connection to
    /// mark end-of-body rather than declaring a `Content-Length` — the
    /// scenario the byte-counting cap has to catch regardless of what any
    /// header claims.
    @MainActor
    private final class OversizedReplyServer {
        private(set) var port: UInt16?
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "io.alas.tests.remote.oversized-reply")

        func start() throws {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                let assigned = listener.port?.rawValue
                Task { @MainActor in
                    guard let self, self.listener === listener else { return }
                    self.port = assigned
                }
            }
            listener.newConnectionHandler = { [queue] conn in
                conn.start(queue: queue)
                var buffer = Data()
                func receiveLoop() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        if let data, !data.isEmpty { buffer.append(data) }
                        if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                            let oversized = String(repeating: "x", count: RemotePeerPairer.maxReplyBytes * 2)
                            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n\(oversized)"
                            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                                conn.cancel()
                            })
                        } else if data != nil {
                            receiveLoop()
                        }
                    }
                }
                receiveLoop()
            }
            listener.start(queue: queue)
        }

        func stop() {
            listener?.cancel()
            listener = nil
        }
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

    // A 401 is only proof the code is dead AT THAT ORIGIN. If a stale advertised
    // address has been reassigned to an unrelated Alas instance, it correctly
    // answers 401 (it has never seen this code) — but the real target, reachable
    // at a later origin, may still redeem it. Stopping on the first 401 would
    // report "expired" for a code that is actually fine.
    @Test func a401AtOneOriginDoesNotStopTheRemainingOnesFromBeingTried() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.1:8765": (401, #"{"error":"pairing failed"}"#),
                        "10.0.0.9:8765": (200, #"{"token":"tok","serverId":"srv-a","name":"Mac A"}"#)], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .paired(token: "tok", serverId: "srv-a", name: "Mac A", origin: "http://10.0.0.9:8765"))
        #expect(recorder.requests.count == 2)
    }

    @Test func expiredCodeIsReportedOnlyAfterEveryOriginRejectsIt() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.1:8765": (401, "{}"), "10.0.0.9:8765": (401, "{}")], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .expiredCode)
        #expect(recorder.requests.count == 2)
    }

    // A 401 seen along the way must not be forgotten just because a LATER
    // origin was simply unreachable: "the code is dead at every origin that
    // answered" is still the more accurate outcome than a bare "unreachable".
    @Test func a401RemembersOverAUnreachableOriginThatFollowsIt() async {
        let p = pairer(["10.0.0.1:8765": (401, "{}")], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .expiredCode)
    }

    @Test func forbiddenIsOriginRejected() async {
        let p = pairer(["10.0.0.1:8765": (403, "{}")], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .originRejected)
    }

    // Same class of bug as the 401 case: a 403 at one origin can be an
    // unrelated Alas instance with federation off, correctly refusing us,
    // while the real target at a later origin has it on and accepts the code.
    @Test func a403AtOneOriginDoesNotStopTheRemainingOnesFromBeingTried() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.1:8765": (403, "{}"),
                        "10.0.0.9:8765": (200, #"{"token":"tok","serverId":"srv-a","name":"Mac A"}"#)], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .paired(token: "tok", serverId: "srv-a", name: "Mac A", origin: "http://10.0.0.9:8765"))
        #expect(recorder.requests.count == 2)
    }

    @Test func originRejectedIsReportedOnlyAfterEveryOriginRejectsIt() async {
        let recorder = Recorder()
        let p = pairer(["10.0.0.1:8765": (403, "{}"), "10.0.0.9:8765": (403, "{}")], recorder: recorder)
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .originRejected)
        #expect(recorder.requests.count == 2)
    }

    // Neither code is a fully reliable global answer, but a dead code is the
    // more fundamental problem to report: fixing a setting on some OTHER Mac
    // would not make an already-expired code work.
    @Test func expiredCodeTakesPriorityOverOriginRejectedWhenBothOccur() async {
        let p = pairer(["10.0.0.1:8765": (403, "{}"), "10.0.0.9:8765": (401, "{}")], recorder: Recorder())
        let outcome = await p.pair(origins: ["http://10.0.0.1:8765", "http://10.0.0.9:8765"], code: "ABC", deviceName: "Mac B", advertisement: ad)
        #expect(outcome == .expiredCode)
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

    // `request.origins` is attacker-controlled — it travels with a peer's
    // own advertisement and is redialed automatically for a reciprocal
    // pair-back — so a malicious or compromised origin returning a reply
    // far larger than any legitimate one must not have its full body
    // materialized in memory. The per-request timeout alone would not
    // catch a connection that keeps a steady trickle of bytes coming.
    @MainActor
    @Test func liveFetchRejectsAnOversizedReply() async throws {
        let server = OversizedReplyServer()
        try server.start()
        defer { server.stop() }
        for _ in 0..<50 where server.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let port = try #require(server.port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/pair")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        await #expect(throws: (any Error).self) {
            _ = try await RemotePeerPairer.boundedFetch(request)
        }
    }
}
