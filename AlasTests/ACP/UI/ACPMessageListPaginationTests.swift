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
}
