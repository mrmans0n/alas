import Testing
import AppKit
@testable import Alas

struct ACPUserScrollEventTests {
    @Test func trackpadScrollIsUserDriven() {
        #expect(ACPUserScrollEvent.isUserDriven(.scrollWheel))
        #expect(ACPUserScrollEvent.isUserDriven(.gesture))
        #expect(ACPUserScrollEvent.isUserDriven(.magnify))
        #expect(ACPUserScrollEvent.isUserDriven(.swipe))
    }

    @Test func scrollerKnobDragIsUserDriven() {
        // Dragging the scrollbar knob arrives as leftMouseDragged.
        #expect(ACPUserScrollEvent.isUserDriven(.leftMouseDragged))
    }

    @Test func scrollbarTrackClickIsUserDriven() {
        // Clicking the scrollbar track to page arrives as a button-held
        // leftMouseDown rather than a scrollWheel; it is still a deliberate
        // user scroll and must be allowed to pause tail-following.
        #expect(ACPUserScrollEvent.isUserDriven(.leftMouseDown))
    }

    @Test func keyboardIsNotTreatedAsScroll() {
        // The transcript ScrollView never holds key focus (the composer does),
        // and currentEvent is app-wide, so keyDown would misattribute composer
        // typing during streaming. It must not count as a user scroll.
        #expect(!ACPUserScrollEvent.isUserDriven(.keyDown))
    }

    @Test func incidentalEventsAreNotUserDriven() {
        #expect(!ACPUserScrollEvent.isUserDriven(.mouseMoved))
        #expect(!ACPUserScrollEvent.isUserDriven(.leftMouseUp))
        #expect(!ACPUserScrollEvent.isUserDriven(nil))
    }
}
