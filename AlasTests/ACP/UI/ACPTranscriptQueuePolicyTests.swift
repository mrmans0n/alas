import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptQueuePolicy")
struct ACPTranscriptQueuePolicyTests {
    private func mkSession() -> ACPSession {
        ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
    }

    // MARK: - queuePosition

    @Test("queuePosition numbers pending items 1-based in FIFO order")
    func queuePositionNumbersFIFO() {
        let statuses: [QueuedPrompt.Status] = [.pending, .pending, .pending]
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 0, statuses: statuses) == 1)
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 1, statuses: statuses) == 2)
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 2, statuses: statuses) == 3)
    }

    @Test("queuePosition skips a .sending head, so the first pending item is still position 1")
    func queuePositionSkipsSendingHead() {
        let statuses: [QueuedPrompt.Status] = [.sending, .pending, .pending]
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 1, statuses: statuses) == 1)
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 2, statuses: statuses) == 2)
    }

    // MARK: - queueHeaderCount

    @Test("queueHeaderCount is visible with a single pending item")
    func queueHeaderCountShowsForOneItem() {
        #expect(ACPTranscriptQueuePolicy.queueHeaderCount(statuses: [.pending]) > 0)
        #expect(ACPTranscriptQueuePolicy.queueHeaderCount(statuses: [.pending]) == 1)
    }

    @Test("queueHeaderCount excludes a .sending head")
    func queueHeaderCountExcludesSending() {
        #expect(ACPTranscriptQueuePolicy.queueHeaderCount(statuses: [.sending]) == 0)
        #expect(ACPTranscriptQueuePolicy.queueHeaderCount(statuses: [.sending, .pending]) == 1)
    }

    // MARK: - canMoveQueueItem

    @Test("canMoveQueueItem allows a plain reorder among pending items")
    func canMoveQueueItemAllowsPlainReorder() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.enqueue(blocks: [.text("c")])
        #expect(ACPTranscriptQueuePolicy.canMoveQueueItem(from: 0, to: 2, queue: s.queue))
        #expect(ACPTranscriptQueuePolicy.canMoveQueueItem(from: 2, to: 0, queue: s.queue))
    }

    @Test("canMoveQueueItem refuses moving a .sending head")
    func canMoveQueueItemRefusesSendingSource() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.markQueueHeadSending()
        #expect(!ACPTranscriptQueuePolicy.canMoveQueueItem(from: 0, to: 1, queue: s.queue))
    }

    @Test("canMoveQueueItem refuses displacing a .sending head from index 0")
    func canMoveQueueItemRefusesDisplacingSendingHead() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.markQueueHeadSending()
        #expect(!ACPTranscriptQueuePolicy.canMoveQueueItem(from: 1, to: 0, queue: s.queue))
    }

    @Test("canMoveQueueItem refuses crossing the scheduled boundary")
    func canMoveQueueItemRefusesCrossingScheduledBoundary() {
        let s = mkSession()
        s.enqueue(blocks: [.text("now")])
        s.enqueueScheduled(blocks: [.text("later")], scheduledAt: .distantFuture)
        #expect(!ACPTranscriptQueuePolicy.canMoveQueueItem(from: 0, to: 1, queue: s.queue))
    }

    @Test("canMoveQueueItem refuses a same-index no-op move")
    func canMoveQueueItemRefusesSameIndex() {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        #expect(!ACPTranscriptQueuePolicy.canMoveQueueItem(from: 0, to: 0, queue: s.queue))
    }
}
