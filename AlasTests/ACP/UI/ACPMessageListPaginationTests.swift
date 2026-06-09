import Testing
@testable import Alas

@Suite("ACPMessageList pagination")
struct ACPMessageListPaginationTests {
    @Test("top indicator is hidden when the full transcript is visible")
    func hiddenWhenFullyVisible() {
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 0,
            isBackfillingOlderMessages: false
        ) == .hidden)
    }

    @Test("top indicator keeps an invisible sentinel after backfill completes")
    func sentinelWhenOlderRowsAreAvailable() {
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 30,
            isBackfillingOlderMessages: false
        ) == .sentinel)
    }

    @Test("top indicator shows spinner only while older rows are backfilling")
    func spinnerWhileBackfilling() {
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 0,
            isBackfillingOlderMessages: true
        ) == .spinner)
        #expect(ACPMessageList.topPaginationIndicator(
            visibleHead: 30,
            isBackfillingOlderMessages: true
        ) == .spinner)
    }

    @Test("queue bubbles render pending items only")
    func queueBubblesRenderPendingItemsOnly() {
        #expect(ACPMessageList.shouldRenderQueueBubble(status: .pending))
        #expect(!ACPMessageList.shouldRenderQueueBubble(status: .sending))
    }

    @Test("queue drops only accept pending items onto pending targets")
    func queueDropsOnlyAcceptPendingItemsOntoPendingTargets() {
        #expect(ACPMessageList.canDropQueuedItem(sourceStatus: .pending, targetStatus: .pending))
        #expect(!ACPMessageList.canDropQueuedItem(sourceStatus: .sending, targetStatus: .pending))
        #expect(!ACPMessageList.canDropQueuedItem(sourceStatus: .pending, targetStatus: .sending))
        #expect(!ACPMessageList.canDropQueuedItem(sourceStatus: nil, targetStatus: .pending))
    }

    @Test("queue header count matches rendered queue bubbles")
    func queueHeaderCountMatchesRenderedQueueBubbles() {
        #expect(ACPMessageList.queueHeaderCount(statuses: []) == 0)
        #expect(ACPMessageList.queueHeaderCount(statuses: [.pending]) == 1)
        #expect(ACPMessageList.queueHeaderCount(statuses: [.sending]) == 0)
        #expect(ACPMessageList.queueHeaderCount(statuses: [.sending, .pending]) == 1)
    }
}
