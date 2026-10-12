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
            ACPTranscriptRenderCaches.of(t).cache(forMessage: id).update(with: "body for \(id)")
        }
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == 10)

        t.setVisibleHead(5)
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == 5)
        for id in ids[0..<5] {
            #expect(!ACPTranscriptRenderCaches.of(t).hasCacheForTests(messageId: id))
        }
        for id in ids[5..<10] {
            #expect(ACPTranscriptRenderCaches.of(t).hasCacheForTests(messageId: id))
        }
    }

    @Test("agent rows with ACP messageId use stable id for markdown cache")
    func agentMessageIdCacheKey() {
        let message = ACPMessage.agent(id: UUID(), messageId: "agent-1", StreamingText("hello"))

        #expect(message.stableId == "acp-agent:agent-1")
    }

    @Test("setVisibleHead is idempotent at the same value")
    func idempotent() {
        let t = ACPTranscript()
        for i in 0..<4 { t.messages.append(.systemNotice(id: UUID(), text: "\(i)")) }
        for id in t.messages.map(\.stableId) {
            ACPTranscriptRenderCaches.of(t).cache(forMessage: id).update(with: id)
        }
        t.setVisibleHead(2)
        let countAfterFirst = ACPTranscriptRenderCaches.of(t).countForTests
        t.setVisibleHead(2)
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == countAfterFirst)
    }

    @Test("setVisibleHead does not drop caches above the head")
    func keepsAboveHead() {
        let t = ACPTranscript()
        for i in 0..<6 { t.messages.append(.systemNotice(id: UUID(), text: "\(i)")) }
        for id in t.messages.map(\.stableId) {
            ACPTranscriptRenderCaches.of(t).cache(forMessage: id).update(with: id)
        }
        t.setVisibleHead(2)
        let after = ACPTranscriptRenderCaches.of(t).countForTests
        t.setVisibleHead(0)
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == after)
    }

    @Test("resetWindowToTail drops caches outside the tail window")
    func resetWindowToTailDropsOutsideTail() {
        let t = ACPTranscript()
        for i in 0..<50 { t.messages.append(.systemNotice(id: UUID(), text: "\(i)")) }
        let ids = t.messages.map(\.stableId)
        for id in ids {
            ACPTranscriptRenderCaches.of(t).cache(forMessage: id).update(with: id)
        }

        t.resetWindowToTail()

        #expect(t.visibleHead == 20)
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == ACPTranscript.tailWindow)
        for id in ids[0..<20] {
            #expect(!ACPTranscriptRenderCaches.of(t).hasCacheForTests(messageId: id))
        }
        for id in ids[20..<50] {
            #expect(ACPTranscriptRenderCaches.of(t).hasCacheForTests(messageId: id))
        }
    }

    @Test("stepping head back drops caches for rows trimmed from the tail")
    func stepHeadBackDropsRowsTrimmedFromTail() {
        let t = ACPTranscript()
        for i in 0..<200 { t.messages.append(.systemNotice(id: UUID(), text: "\(i)")) }
        let ids = t.messages.map(\.stableId)
        for id in ids {
            ACPTranscriptRenderCaches.of(t).cache(forMessage: id).update(with: id)
        }

        t.setVisibleWindow(containing: 110)
        t.stepHeadBack()

        #expect(t.visibleHead == 80)
        #expect(t.visibleTail == 170)
        for id in ids[170..<200] {
            #expect(!ACPTranscriptRenderCaches.of(t).hasCacheForTests(messageId: id))
        }
    }

    @Test("discardRenderState empties the cache map")
    func resetClears() {
        let t = ACPTranscript()
        t.messages.append(.systemNotice(id: UUID(), text: "x"))
        ACPTranscriptRenderCaches.of(t).cache(forMessage: t.messages[0].stableId).update(with: "x")
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == 1)
        t.discardRenderState()
        #expect(ACPTranscriptRenderCaches.of(t).countForTests == 0)
    }
}
