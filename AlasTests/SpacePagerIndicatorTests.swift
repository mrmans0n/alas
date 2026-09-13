import Foundation
import AppKit
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
        #expect(SpacePagingIntent.offset(deltaX: 48, deltaY: 4) == -1)
        #expect(SpacePagingIntent.offset(deltaX: -48, deltaY: 4) == 1)
        #expect(SpacePagingIntent.offset(deltaX: 8, deltaY: 30) == nil)
        #expect(SpacePagingIntent.offset(deltaX: 12, deltaY: 2) == nil)
    }

    @Test func pausedGestureCannotReverseOrPageAgain() {
        var gate = SpacePagingScrollGate()
        #expect(gate.consume(deltaX: -30, deltaY: 0, phase: .began, momentumPhase: [], now: 0).page == 1)
        let reversal = gate.consume(deltaX: 60, deltaY: 0, phase: .changed, momentumPhase: [], now: 0.6)
        #expect(reversal.page == nil)
        #expect(reversal.capturesScroll)
        #expect(gate.consume(deltaX: 30, deltaY: 0, phase: .ended, momentumPhase: [], now: 0.7).page == nil)
        #expect(gate.consume(deltaX: 30, deltaY: 0, phase: .began, momentumPhase: [], now: 0.71).page == -1)
    }

    @Test func momentumNeverNavigatesEvenAfterLongPause() {
        var gate = SpacePagingScrollGate()
        #expect(gate.consume(deltaX: -30, deltaY: 0, phase: .began, momentumPhase: [], now: 0).page == 1)
        #expect(gate.consume(deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: [], now: 0.1).page == nil)
        let momentum = gate.consume(deltaX: 60, deltaY: 0, phase: [], momentumPhase: .changed, now: 2)
        #expect(momentum.page == nil)
        #expect(momentum.capturesScroll)
        var freshGate = SpacePagingScrollGate()
        #expect(freshGate.consume(deltaX: -60, deltaY: 0, phase: [], momentumPhase: .began, now: 3).page == nil)
    }

    @Test func slowHorizontalSwipeAccumulatesSmallDeltas() {
        var gate = SpacePagingScrollGate()
        #expect(gate.consume(deltaX: -8, deltaY: 1, phase: .began, momentumPhase: [], now: 0).page == nil)
        #expect(gate.consume(deltaX: -8, deltaY: 1, phase: .changed, momentumPhase: [], now: 0.1).page == nil)
        #expect(gate.consume(deltaX: -8, deltaY: 1, phase: .changed, momentumPhase: [], now: 0.2).page == 1)
    }

    @Test func verticalGestureCannotTurnIntoPaging() {
        var gate = SpacePagingScrollGate()
        #expect(!gate.consume(deltaX: 1, deltaY: 12, phase: .began, momentumPhase: [], now: 0).capturesScroll)
        let diagonal = gate.consume(deltaX: -60, deltaY: 2, phase: .changed, momentumPhase: [], now: 0.1)
        #expect(diagonal.page == nil)
        #expect(!diagonal.capturesScroll)
    }

    @Test func unphasedWheelRearmsOnlyAfterAllEventsGoQuiet() {
        var gate = SpacePagingScrollGate()
        #expect(gate.consume(deltaX: -30, deltaY: 0, phase: [], momentumPhase: [], now: 0).page == 1)
        #expect(gate.consume(deltaX: -1, deltaY: 0, phase: [], momentumPhase: [], now: 0.3).page == nil)
        #expect(gate.consume(deltaX: 60, deltaY: 0, phase: [], momentumPhase: [], now: 0.5).page == nil)
        #expect(gate.consume(deltaX: 30, deltaY: 0, phase: [], momentumPhase: [], now: 1).page == -1)
    }

    @Test func gestureMustBeginInsidePagerAndCancellationEndsIt() {
        var gate = SpacePagingScrollGate()
        #expect(gate.consume(deltaX: -60, deltaY: 0, phase: .changed, momentumPhase: [], now: 0).page == nil)
        #expect(gate.consume(deltaX: -8, deltaY: 0, phase: .began, momentumPhase: [], now: 1).page == nil)
        #expect(gate.consume(deltaX: -8, deltaY: 0, phase: .cancelled, momentumPhase: [], now: 1.1).page == nil)
        #expect(gate.consume(deltaX: -60, deltaY: 0, phase: .changed, momentumPhase: [], now: 1.2).page == nil)
        #expect(gate.consume(deltaX: -30, deltaY: 0, phase: .began, momentumPhase: [], now: 1.3).page == 1)
    }

    @Test func pagerStopsAtEnds() {
        #expect(SpacePagerNavigation.destination(current: 0, offset: -1, count: 3) == nil)
        #expect(SpacePagerNavigation.destination(current: 2, offset: 1, count: 3) == nil)
        #expect(SpacePagerNavigation.destination(current: 0, offset: 1, count: 3) == 1)
        #expect(SpacePagerNavigation.destination(current: 2, offset: -1, count: 3) == 1)
        #expect(SpacePagerNavigation.destination(current: 0, offset: 1, count: 1) == nil)
        #expect(SpacePagerNavigation.destination(current: 0, offset: 1, count: 0) == nil)
    }

    @Test func pagerStripKeepsEverySpaceAtAStablePosition() {
        let spaces = [space(id: "first"), space(id: "second"), space(id: "third")]

        #expect(SpacePagerLayout.offset(activeSpaceID: "first", spaces: spaces, pageWidth: 240) == 0)
        #expect(SpacePagerLayout.offset(activeSpaceID: "second", spaces: spaces, pageWidth: 240) == -240)
        #expect(SpacePagerLayout.offset(activeSpaceID: "third", spaces: spaces, pageWidth: 240) == -480)
    }

    @Test func spaceIconRejectsNerdFontPrivateUseGlyphs() {
        #expect(SpaceIcon.sanitized("\u{F015}", fallback: "🏠") == "🏠")
    }

    @Test func spaceIconAcceptsMultiScalarEmoji() {
        #expect(SpaceIcon.sanitized("🙈", fallback: "🏠") == "🙈")
    }

    private func space(id: String) -> SpaceConfig {
        SpaceConfig(
            id: id,
            name: id,
            emoji: "🏠",
            projectIds: [],
            members: nil,
            lastSelectedWorktreeId: nil,
            createdAt: .distantPast
        )
    }
}
