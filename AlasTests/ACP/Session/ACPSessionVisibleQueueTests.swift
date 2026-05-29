import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPSession visibleQueueCount")
struct ACPSessionVisibleQueueTests {
    private func mkSession() -> ACPSession {
        ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
    }

    @Test("empty queue → 0 visible")
    func empty() {
        #expect(mkSession().visibleQueueCount == 0)
    }

    @Test("single .pending → 1 visible")
    func singlePending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        #expect(s.visibleQueueCount == 1)
    }

    @Test("single .sending head → 0 visible")
    func singleSending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.markQueueHeadSending()
        #expect(s.visibleQueueCount == 0)
    }

    @Test(".sending head + two .pending → 2 visible")
    func sendingPlusPending() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.enqueue(blocks: [.text("c")])
        s.markQueueHeadSending()
        #expect(s.queue.count == 3)
        #expect(s.visibleQueueCount == 2)
    }

    @Test("retry-eligible .pending with lastError stays visible")
    func pendingWithErrorStaysVisible() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.markQueueHeadSending()
        s.setQueueHeadError("boom")
        #expect(s.queue[0].status == .pending)
        #expect(s.queue[0].lastError == "boom")
        #expect(s.visibleQueueCount == 1)
    }
}
