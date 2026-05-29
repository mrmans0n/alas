import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession byte accounting")
struct ACPSessionByteAccountingTests {
    @Test("transcriptByteEstimate sums utf8 bytes across all message kinds")
    func transcriptSums() {
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "w1", title: "t")
        session.transcript.messages.append(.user(id: UUID(), text: "hello", attachments: []))
        session.transcript.messages.append(.agent(id: UUID(), StreamingText("world!")))
        session.transcript.messages.append(.systemNotice(id: UUID(), text: "x"))
        #expect(session.transcriptByteEstimate() == 12)
    }

    @Test("transcriptByteEstimate counts toolCall content, preview, title, locations")
    func toolCallBytes() {
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "w1", title: "t")
        let tc = ACPMessage.ToolCall(
            toolCallId: "tc1", title: "read",
            status: "completed", content: "0123456789",
            preview: "0…", locations: ["/a/b"])
        session.transcript.messages.append(.toolCall(tc))
        let expected: UInt64 = UInt64(
            "0123456789".utf8.count
            + "0…".utf8.count
            + "read".utf8.count
            + "/a/b".utf8.count
        )
        #expect(session.transcriptByteEstimate() == expected)
    }

    @Test("markdownCacheByteEstimate sums lastFullText across caches")
    func markdownCacheSums() {
        let session = ACPSession(id: "s1", agentId: "claude", worktreeId: "w1", title: "t")
        let cacheA = session.transcript.markdownCache(forMessage: "a")
        cacheA.update(with: String(repeating: "x", count: 1000))
        let cacheB = session.transcript.markdownCache(forMessage: "b")
        cacheB.update(with: String(repeating: "y", count: 500))
        let bytes = session.markdownCacheByteEstimate()
        #expect(bytes >= 1500)
    }
}
