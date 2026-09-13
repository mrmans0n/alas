import Testing
@testable import Alas

struct PaneBandLayoutTests {
    @Test func innerPaddingKeepsContentAtTheSameX() {
        // A band moves in by `outerHorizontal`, so its inner padding has to
        // give back exactly that much for header text to stay aligned with
        // the plain rows beneath it.
        #expect(PaneBandLayout.innerHorizontal(12) + PaneBandLayout.outerHorizontal == 12)
        #expect(PaneBandLayout.innerHorizontal(10) + PaneBandLayout.outerHorizontal == 10)
    }

    @Test func innerPaddingNeverGoesNegative() {
        // Insets narrower than the outer gap clamp at zero rather than
        // pulling content back out over the band's edge.
        #expect(PaneBandLayout.innerHorizontal(4) == 0)
        #expect(PaneBandLayout.innerHorizontal(0) == 0)
    }

    @Test func collapsedDrawerIsBare() {
        // No card: content sits at the column edge, only a hairline marks it.
        let layout = PaneDrawerLayout(expanded: false)
        #expect(layout.outerHorizontal == 0)
        #expect(layout.cornerRadius == 0)
        #expect(layout.showsHairline)
        #expect(layout.innerHorizontal(12) == 12)
    }

    @Test func expandedDrawerBecomesABand() {
        // The card takes the same geometry as the section headers, and the
        // content gives back the outer gap so it does not shift on toggle.
        let layout = PaneDrawerLayout(expanded: true)
        #expect(layout.outerHorizontal == PaneBandLayout.outerHorizontal)
        #expect(layout.cornerRadius == PaneBandLayout.cornerRadius)
        #expect(layout.bottom == PaneBandLayout.paneEdge)
        #expect(!layout.showsHairline)
        #expect(layout.innerHorizontal(12) + layout.outerHorizontal == 12)
    }

    @Test func drawerToggleRespectsReduceMotion() {
        #expect(PaneDrawerLayout.animation(reduceMotion: true) == nil)
        #expect(PaneDrawerLayout.animation(reduceMotion: false) != nil)
    }

    @Test func chevronTurnsAQuarterWhenOpen() {
        #expect(PaneDrawerLayout(expanded: false).chevronAngle == .degrees(0))
        #expect(PaneDrawerLayout(expanded: true).chevronAngle == .degrees(90))
    }

    @Test func bandsAreRoundedAndSeparated() {
        #expect(PaneBandLayout.cornerRadius > 0)
        #expect(PaneBandLayout.outerHorizontal > 0)
        #expect(PaneBandLayout.outerVertical > 0)
        // The pane's outer edge gets more air than the gap between bands.
        #expect(PaneBandLayout.paneEdge > PaneBandLayout.outerVertical)
    }
}
