import Foundation
import Testing
@testable import AlasCore

@Suite struct RemotePairingClientTests {
    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        let answers: [String: Result<(Int, String), URLError>]
        init(_ answers: [String: Result<(Int, String), URLError>]) { self.answers = answers }
        var requests: [URLRequest] { lock.withLock { seen } }
        var transport: RemotePairingClient.Transport {
            { request in
                self.lock.withLock { self.seen.append(request) }
                let origin = request.url!.absoluteString.replacingOccurrences(of: "/pair", with: "")
                let (status, body) = try self.answers[origin]!.get()
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }
        }
    }

    private let a = "http://10.0.0.1:8080"
    private let b = "http://10.0.0.2:8080"
    private let ok = "{\"token\":\"t\",\"serverId\":\"s\",\"name\":\"Mac\",\"publicKey\":\"k\"}"

    private func pair(_ fake: Fake, _ origins: [String]) async throws(RemotePairingError) -> RemotePairingResult {
        try await RemotePairingClient(transport: fake.transport).pair(origins: origins, code: "123456", deviceName: "Phone")
    }

    @Test func pairsWithTheFirstOriginThatAnswers() async throws {
        let fake = Fake([a: .failure(URLError(.timedOut)), b: .success((200, ok))])
        let result = try await pair(fake, [a, b])
        #expect(result.origin == b)
        #expect(result.token == "t")
        #expect(result.publicKey == "k")
    }

    @Test func stopsAtTheFirstRejectedCode() async {
        let fake = Fake([a: .success((401, "{}")), b: .success((200, ok))])
        await #expect(throws: RemotePairingError.codeRejected) { try await pair(fake, [a, b]) }
        #expect(fake.requests.count == 1)
    }

    @Test func triesTheNextOriginWhenOneIsNotAllowed() async throws {
        let fake = Fake([a: .success((403, "{}")), b: .success((200, ok))])
        #expect(try await pair(fake, [a, b]).origin == b)
        let denied = Fake([a: .success((403, "{}"))])
        await #expect(throws: RemotePairingError.originNotAllowed) { try await pair(denied, [a]) }
    }

    @Test(arguments: [
        Result<(Int, String), URLError>.failure(URLError(.cannotConnectToHost)),
        .success((200, "{\"token\":\"\"}")),
        .success((200, "not json")),
    ])
    func reportsUnreachableWhenNothingUsableAnswers(_ answer: Result<(Int, String), URLError>) async {
        let fake = Fake([a: answer])
        await #expect(throws: RemotePairingError.unreachable) { try await pair(fake, [a]) }
    }

    @Test func skipsLoopbackOrigins() async {
        let loopback = ["http://127.0.0.1:1", "http://127.1.2.3:1", "http://localhost:1", "http://[::1]:1"]
        let fake = Fake([:])
        await #expect(throws: RemotePairingError.unreachable) { try await pair(fake, loopback) }
        #expect(fake.requests.isEmpty)
    }

    @Test func sendsCodeAndDeviceNameAsJSON() async throws {
        let fake = Fake([a: .success((200, ok))])
        _ = try await pair(fake, [a])
        let request = try #require(fake.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == a + "/pair")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(request.httpBody))
        #expect(body == ["code": "123456", "deviceName": "Phone"])
    }
}
