import Foundation
import Testing
@testable import Alas

@Suite("QueuedPrompt")
struct QueuedPromptTests {
    @Test("round-trips JSON with default status .pending")
    func roundTripDefault() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = QueuedPrompt(
            id: id,
            blocks: [.text("hello"), .resourceLink(uri: "file:///a.txt", name: "a.txt")],
            enqueuedAt: date,
            status: .pending,
            lastError: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: data)
        #expect(decoded == original)
    }

    @Test("normalizeAfterRestore flips .sending to .pending and clears lastError untouched")
    func normalize() {
        let q = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                             enqueuedAt: .init(), status: .sending, lastError: "boom")
        let n = q.normalizedAfterRestore()
        #expect(n.status == .pending)
        #expect(n.lastError == "boom")    // lastError survives; only status flips
    }

    @Test("encodes status as raw string")
    func statusRaw() throws {
        let q = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                             enqueuedAt: .init(), status: .sending, lastError: nil)
        let json = String(data: try JSONEncoder().encode(q), encoding: .utf8)!
        #expect(json.contains("\"status\":\"sending\""))
    }
}
