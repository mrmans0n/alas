import Testing
@testable import Alas

@Suite("ACPComposerActionButton metrics")
struct ACPComposerActionButtonMetricsTests {
    @Test("queue badge top outset is inside the split button layout bounds")
    func queueBadgeTopOutsetIsAccountedFor() {
        #expect(ACPComposerActionButtonMetrics.badgeTopOutset == 6)
        #expect(ACPComposerActionButtonMetrics.badgeTopOutset < ACPComposerActionButtonMetrics.badgeMinHeight)
        #expect(ACPComposerActionButtonMetrics.capsuleHeight + ACPComposerActionButtonMetrics.badgeTopOutset
                >= ACPComposerActionButtonMetrics.capsuleHeight)
    }

    @Test("segment divider is an inset hairline inside the capsule")
    func segmentDividerIsInsetHairline() {
        #expect(ACPComposerActionButtonMetrics.dividerWidth == 1)
        #expect(ACPComposerActionButtonMetrics.dividerHeight < ACPComposerActionButtonMetrics.capsuleHeight)
        #expect(ACPComposerActionButtonMetrics.dividerOnAccentOpacity > 0)
        #expect(ACPComposerActionButtonMetrics.dividerOnAccentOpacity < 1)
    }

    @Test("badge remains compact relative to the composer action capsule")
    func badgeStaysCompactRelativeToActionCapsule() {
        #expect(ACPComposerActionButtonMetrics.badgeMinHeight < ACPComposerActionButtonMetrics.capsuleHeight)
        #expect(ACPComposerActionButtonMetrics.badgeMinWidth <= ACPComposerActionButtonMetrics.capsuleHeight)
    }
}
