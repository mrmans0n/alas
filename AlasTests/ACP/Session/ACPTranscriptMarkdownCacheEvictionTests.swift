import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscript markdown cache eviction")
struct ACPTranscriptMarkdownCacheEvictionTests {
    @Test("advancing visibleHead drops caches for messages now below head")
    func dropsBelowHead() {
        let t = ACPTranscript()
        for i in 0..<10 {
            t.messages.append(.systemNotice(id: UUID(), text: "n\(i)"))
        }
        let ids = t.messages.map(\.stableId)
        for id in ids {
            t.markdownCache(forMessage: id).update(with: "body for \(id)")
        }
        #expect(t.markdownCacheCountForTests == 10)

        t.setVisibleHead(5)
        #expect(t.markdownCacheCountForTests == 5)
        for id in ids[0..<5] {
            #expect(!t.hasMarkdownCacheForTests(messageId: id))
        }
        for id in ids[5..<10] {
            #expect(t.hasMarkdownCacheForTests(messageId: id))
        }
    }

    @Test("agent rows with ACP messageId use stable id for markdown cache")
    func agentMessageIdCacheKey() {
        let message = ACPMessage.agent(id: UUID(), messageId: "agent-1", StreamingText("hello"))

        #expect(ACPMessageList.markdownCacheMessageId(for: message) == "agent-1")
    }

    @Test("setVisibleHead is idempotent at the same value")
    func idempotent() {
        let t = ACPTranscript()
        for i in 0..<4 { t.messages.append(.systemNotice(id: UUID(), text: "\(i)")) }
        for id in t.messages.map(\.stableId) {
            t.markdownCache(forMessage: id).update(with: id)
        }
        t.setVisibleHead(2)
        let countAfterFirst = t.markdownCacheCountForTests
        t.setVisibleHead(2)
        #expect(t.markdownCacheCountForTests == countAfterFirst)
    }

    @Test("setVisibleHead does not drop caches above the head")
    func keepsAboveHead() {
        let t = ACPTranscript()
        for i in 0..<6 { t.messages.append(.systemNotice(id: UUID(), text: "\(i)")) }
        for id in t.messages.map(\.stableId) {
            t.markdownCache(forMessage: id).update(with: id)
        }
        t.setVisibleHead(2)
        let after = t.markdownCacheCountForTests
        t.setVisibleHead(0)
        #expect(t.markdownCacheCountForTests == after)
    }

    @Test("resetMarkdownCaches empties the cache map")
    func resetClears() {
        let t = ACPTranscript()
        t.messages.append(.systemNotice(id: UUID(), text: "x"))
        t.markdownCache(forMessage: t.messages[0].stableId).update(with: "x")
        #expect(t.markdownCacheCountForTests == 1)
        t.resetMarkdownCaches()
        #expect(t.markdownCacheCountForTests == 0)
    }
}
