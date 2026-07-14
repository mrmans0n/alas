import Testing
@testable import Alas

struct PaneDragMathTests {
    // MARK: resolvedWidth

    @Test func resolvedWidthAddsTranslationToStartWidth() {
        let width = PaneDragMath.resolvedWidth(startWidth: 244, translation: 30, min: 200, max: 420)
        #expect(width == 274)
    }

    @Test func resolvedWidthClampsToMin() {
        let width = PaneDragMath.resolvedWidth(startWidth: 244, translation: -500, min: 200, max: 420)
        #expect(width == 200)
    }

    @Test func resolvedWidthClampsToMax() {
        let width = PaneDragMath.resolvedWidth(startWidth: 244, translation: 500, min: 200, max: 420)
        #expect(width == 420)
    }

    // The reason absolute anchoring beats delta accumulation: after
    // overshooting past a bound, dragging back re-tracks the cursor exactly
    // instead of staying desynced by the clamped-away distance.
    @Test func resolvedWidthReTracksCursorAfterOvershoot() {
        let overshot = PaneDragMath.resolvedWidth(startWidth: 244, translation: 500, min: 200, max: 420)
        #expect(overshot == 420)
        let back = PaneDragMath.resolvedWidth(startWidth: 244, translation: 50, min: 200, max: 420)
        #expect(back == 294)
    }

    @Test func resolvedWidthIgnoresNonFiniteTranslation() {
        #expect(PaneDragMath.resolvedWidth(startWidth: 244, translation: .nan, min: 200, max: 420) == 244)
        #expect(PaneDragMath.resolvedWidth(startWidth: 244, translation: .infinity, min: 200, max: 420) == 244)
    }

    @Test func resolvedWidthFallsBackToMinForNonFiniteStart() {
        #expect(PaneDragMath.resolvedWidth(startWidth: .nan, translation: 30, min: 200, max: 420) == 230)
    }

    // MARK: pixelAligned

    @Test func pixelAlignedRoundsToRetinaGrid() {
        #expect(PaneDragMath.pixelAligned(100.3, scale: 2) == 100.5)
        #expect(PaneDragMath.pixelAligned(100.2, scale: 2) == 100.0)
    }

    @Test func pixelAlignedRoundsToIntegerAtScaleOne() {
        #expect(PaneDragMath.pixelAligned(100.5, scale: 1) == 101.0)
    }

    @Test func pixelAlignedPassesThroughInvalidScale() {
        #expect(PaneDragMath.pixelAligned(100.3, scale: 0) == 100.3)
        #expect(PaneDragMath.pixelAligned(100.3, scale: -1) == 100.3)
        #expect(PaneDragMath.pixelAligned(100.3, scale: .nan) == 100.3)
    }

    @Test func pixelAlignedPassesThroughNonFiniteValue() {
        #expect(PaneDragMath.pixelAligned(.infinity, scale: 2) == .infinity)
    }
}
