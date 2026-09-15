import Foundation
import Testing
@testable import Alas

struct FilesBookmarksPaneMetricsTests {
    @Test func defaultHeightSitsBetweenTheBounds() {
        // 25%-50% of 800 is 200...400.
        #expect(FilesBookmarksPaneMetrics.defaultHeight(containerHeight: 800) == 300)
    }

    @Test func clampsBelowTheMinimumUpToAQuarterOfThePane() {
        #expect(FilesBookmarksPaneMetrics.clamp(40, containerHeight: 800) == 200)
    }

    @Test func clampsAboveTheMaximumDownToHalfOfThePane() {
        #expect(FilesBookmarksPaneMetrics.clamp(9000, containerHeight: 800) == 400)
    }

    @Test func keepsHeightsInsideTheBounds() {
        #expect(FilesBookmarksPaneMetrics.clamp(250, containerHeight: 800) == 250)
    }

    @Test func fallsBackToTheDefaultContainerWhenThePaneHasNoHeightYet() {
        // A zero-height container would otherwise collapse the drawer to nothing.
        #expect(FilesBookmarksPaneMetrics.clamp(250, containerHeight: 0) > 0)
    }
}
