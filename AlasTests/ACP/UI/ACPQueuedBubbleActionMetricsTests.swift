import CoreGraphics
import Testing
@testable import Alas

@Suite("ACPQueuedBubble action metrics")
struct ACPQueuedBubbleActionMetricsTests {
    @Test("reserved action width accounts for every action slot")
    func reservedWidthAccountsForActionSlots() {
        #expect(ACPQueuedBubbleActionMetrics.reservedButtonSlots == 4)
        #expect(ACPQueuedBubbleActionMetrics.reservedWidth == 76)
    }

    @Test("edit and remove slots keep stable offsets when retry is hidden")
    func editAndRemoveSlotsStayStableWhenRetryIsHidden() {
        let button = ACPQueuedBubbleActionMetrics.buttonSize
        let spacing = ACPQueuedBubbleActionMetrics.buttonSpacing

        let editSlotLeading = 2 * (button + spacing)
        let removeSlotLeading = 3 * (button + spacing)

        #expect(editSlotLeading < ACPQueuedBubbleActionMetrics.reservedWidth)
        #expect(removeSlotLeading + button == ACPQueuedBubbleActionMetrics.reservedWidth)
    }

    @Test("left actions reserve a stable lane beside queued content")
    func leftActionsReserveStableLaneBesideQueuedContent() {
        #expect(ACPQueuedBubbleActionMetrics.actionGroupToContentSpacing == 8)
        #expect(ACPQueuedBubbleActionMetrics.minimumLeadingSpacerWidth == 16)
        #expect(ACPQueuedBubbleActionMetrics.reservedAccessoryWidth == 84)
    }
}
