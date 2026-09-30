import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptQueuePolicy")
struct ACPTranscriptQueuePolicyTests {
    private func mkSession() -> ACPSession {
        ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
    }

    private func queue(_ statuses: [QueuedPrompt.Status], delegatedAt delegated: Set<Int> = []) -> [QueuedPrompt] {
        statuses.enumerated().map { idx, status in
            QueuedPrompt(
                blocks: [.text("\(idx)")],
                status: status,
                delegatedSource: delegated.contains(idx)
                    ? ACPDelegatedPromptSource(sessionId: "child", messageId: "m\(idx)")
                    : nil
            )
        }
    }

    // MARK: - queuePosition

    @Test("queuePosition numbers rendered items 1-based, skipping a .sending head and delegated prompts")
    func queuePositionSkipsUnrenderedItems() {
        let fifo = queue([.pending, .pending, .pending])
        #expect([0, 1, 2].map { ACPTranscriptQueuePolicy.queuePosition(at: $0, queue: fifo) } == [1, 2, 3])
        let mixed = queue([.sending, .pending, .pending, .pending], delegatedAt: [2])
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 1, queue: mixed) == 1)
        #expect(ACPTranscriptQueuePolicy.queuePosition(at: 3, queue: mixed) == 2)
    }

    // MARK: - queueHeaderCount

    @Test(
        "queueHeaderCount counts only the user's pending items",
        arguments: [
            ([QueuedPrompt.Status.pending], [Int](), 1),
            ([.sending], [], 0),
            ([.sending, .pending], [], 1),
            ([.pending, .pending], [1], 1),
            ([.pending], [0], 0),
        ]
    )
    func queueHeaderCountCountsUserPendingItems(
        statuses: [QueuedPrompt.Status], delegated: [Int], expected: Int
    ) {
        #expect(ACPTranscriptQueuePolicy.queueHeaderCount(queue: queue(statuses, delegatedAt: Set(delegated))) == expected)
    }

    // MARK: - adjacentRenderedIndex

    @Test("adjacentRenderedIndex steps over hidden delegated prompts")
    func adjacentRenderedIndexSkipsDelegated() {
        let items = queue([.pending, .pending, .pending], delegatedAt: [1])
        #expect(ACPTranscriptQueuePolicy.adjacentRenderedIndex(from: 2, step: -1, queue: items) == 0)
        #expect(ACPTranscriptQueuePolicy.adjacentRenderedIndex(from: 0, step: 1, queue: items) == 2)
        #expect(ACPTranscriptQueuePolicy.adjacentRenderedIndex(from: 2, step: 1, queue: items) == nil)
        let trailing = queue([.pending, .pending], delegatedAt: [1])
        #expect(ACPTranscriptQueuePolicy.adjacentRenderedIndex(from: 0, step: 1, queue: trailing) == nil)
    }

    @Test("moving to the adjacent rendered index reorders past a hidden delegated prompt")
    func moveToAdjacentRenderedIndexReorders() throws {
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("report")], delegatedSource: ACPDelegatedPromptSource(sessionId: "child", messageId: "m"))
        s.enqueue(blocks: [.text("b")])
        let up = try #require(ACPTranscriptQueuePolicy.adjacentRenderedIndex(from: 2, step: -1, queue: s.queue))
        s.moveInQueue(from: 2, to: up)
        #expect(s.queue.map(\.blocks) == [[.text("b")], [.text("a")], [.text("report")]])
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

    @Test("canMoveQueueItem refuses moving the last item past the end (a no-op)")
    func canMoveQueueItemRefusesLastItemPastEnd() {
        // Regression: "Move down" on the tail item computes dst ==
        // queue.count. Removing the item and reinserting at
        // min(dst, queue.count) lands it back in the same trailing slot,
        // so the affordance must be disabled rather than look live and
        // silently do nothing.
        let s = mkSession()
        s.enqueue(blocks: [.text("a")])
        s.enqueue(blocks: [.text("b")])
        s.enqueue(blocks: [.text("c")])
        #expect(!ACPTranscriptQueuePolicy.canMoveQueueItem(from: 2, to: 3, queue: s.queue))
        // A middle item moving one slot down IS a real reorder and stays allowed.
        #expect(ACPTranscriptQueuePolicy.canMoveQueueItem(from: 1, to: 2, queue: s.queue))
    }
}
