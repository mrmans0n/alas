import Foundation
import Testing
@testable import Alas

@MainActor
struct SpacePagerIndicatorTests {
    @Test func inactiveEmojiUsesGrayscaleStyle() {
        #expect(SpacePagerItemStyle.style(isActive: true).opacity == 1)
        #expect(SpacePagerItemStyle.style(isActive: false).opacity < 1)
        #expect(!SpacePagerItemStyle.style(isActive: true).isGrayscale)
        #expect(SpacePagerItemStyle.style(isActive: false).isGrayscale)
    }

    @Test func horizontalScrollClassifiesSpacePagingDirection() {
        #expect(SpacePagingIntent.offset(deltaX: 48, deltaY: 4) == 1)
        #expect(SpacePagingIntent.offset(deltaX: -48, deltaY: 4) == -1)
        #expect(SpacePagingIntent.offset(deltaX: 8, deltaY: 30) == nil)
        #expect(SpacePagingIntent.offset(deltaX: 12, deltaY: 2) == nil)
    }

    @Test func scrollGateAllowsOnlyOnePagePerGestureBurst() {
        var gate = SpacePagingScrollGate()

        #expect(gate.consume(offset: 1, now: 0) == 1)
        #expect(gate.consume(offset: 1, now: 0.08) == nil)
        #expect(gate.consume(offset: -1, now: 0.12) == nil)
        #expect(gate.consume(offset: -1, now: 0.60) == -1)
    }

    @Test func scrollGateRearmsAfterQuietGapNotMomentumDuration() {
        var gate = SpacePagingScrollGate()

        #expect(gate.consume(offset: 1, now: 0) == 1)
        #expect(gate.consume(offset: 1, now: 0.20) == nil)
        #expect(gate.consume(offset: -1, now: 0.39) == nil)
        #expect(gate.consume(offset: -1, now: 0.75) == -1)
    }

    @Test func spaceIconRejectsNerdFontPrivateUseGlyphs() {
        #expect(SpaceIcon.sanitized("\u{F015}", fallback: "🏠") == "🏠")
    }

    @Test func spaceIconAcceptsMultiScalarEmoji() {
        #expect(SpaceIcon.sanitized("🙈", fallback: "🏠") == "🙈")
    }
}
