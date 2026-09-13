import Testing
@testable import Alas

struct PaneCollapseMotionTests {
    @Test func sidebarContentLagsTowardTheLeadingEdge() {
        // The pane edge travels the full width; the content trails it so the
        // divider visibly overtakes what it hides.
        #expect(PaneCollapseMotion.parallaxOffset(edge: .leading, width: 200) == -90)
    }

    @Test func rightPaneContentLagsTowardTheTrailingEdge() {
        #expect(PaneCollapseMotion.parallaxOffset(edge: .trailing, width: 200) == 90)
    }

    @Test func contentAlwaysTravelsLessThanThePaneEdge() {
        #expect(PaneCollapseMotion.parallaxFraction > 0)
        #expect(PaneCollapseMotion.parallaxFraction < 1)
    }

    @Test func zeroWidthPaneDoesNotMove() {
        #expect(PaneCollapseMotion.parallaxOffset(edge: .leading, width: 0) == 0)
    }

    @Test func reduceMotionDisablesTheAnimation() {
        #expect(PaneCollapseMotion.animation(reduceMotion: true) == nil)
        #expect(PaneCollapseMotion.animation(reduceMotion: false) != nil)
    }
}
