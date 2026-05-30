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

    @Test func plainMouseDownIsNotScrollIntent() {
        // A bare leftMouseDown is "any left click" — it can't be distinguished
        // from clicking a transcript control (expanding/collapsing a card, the
        // copy button) by event type alone. If such a click coincides with a
        // streaming/layout reflow that shifts the clip view upward, treating it
        // as a scroll would re-latch the false pause this change prevents. Only
        // the knob drag (leftMouseDragged) counts; track-click paging is a rare
        // interaction not worth that regression.
        #expect(!ACPUserScrollEvent.isUserDriven(.leftMouseDown))
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
