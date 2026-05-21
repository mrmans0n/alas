import Testing
import Foundation
@testable import Alas

struct ImageDiffSwipeViewTests {
    @Test func handleFractionClampsBelowZero() {
        #expect(ImageDiffSwipeView.clampFraction(-0.5) == 0.0)
    }

    @Test func handleFractionClampsAboveOne() {
        #expect(ImageDiffSwipeView.clampFraction(1.7) == 1.0)
    }

    @Test func handleFractionPassesThroughValid() {
        #expect(ImageDiffSwipeView.clampFraction(0.42) == 0.42)
    }
}
