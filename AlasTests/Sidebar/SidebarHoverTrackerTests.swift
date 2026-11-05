import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
private final class HoverLog {
    var hovered: Int?
}

@MainActor
struct SidebarHoverTrackerTests {
    /// Records each row's hover transitions.
    @MainActor
    private final class Rows {
        let tracker = SidebarHoverTracker(settleDelay: 0)
        var log: [String] = []

        @discardableResult
        func add(_ name: String, y: CGFloat, height: CGFloat = 40, x: CGFloat = 0, width: CGFloat = 200) -> UUID {
            let id = UUID()
            tracker.update(id, frame: CGRect(x: x, y: y, width: width, height: height)) { [unowned self] in
                log.append(($0 ? "+" : "-") + name)
            }
            return id
        }

        func take() -> [String] {
            defer { log = [] }
            return log
        }
    }

    @Test func movingBetweenRowsOnlyTouchesTheTwoRows() {
        let rows = Rows()
        rows.add("a", y: 0)
        rows.add("b", y: 40)
        let lastRow = rows.add("c", y: 80)

        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 10))
        #expect(rows.take() == ["+a"])
        rows.tracker.pointerMoved(to: CGPoint(x: 20, y: 20))
        #expect(rows.take().isEmpty)
        // Exit before entry in both directions, whatever order rows are stored in.
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 50))
        #expect(rows.take() == ["-a", "+b"])
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 10))
        #expect(rows.take() == ["-b", "+a"])
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 50))
        #expect(rows.take() == ["-a", "+b"])
        rows.tracker.pointerExited()
        #expect(rows.take() == ["-b"])

        // A row that left the list gets no more callbacks.
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 90))
        #expect(rows.take() == ["+c"])
        rows.tracker.remove(lastRow)
        rows.tracker.pointerExited()
        #expect(rows.take().isEmpty)
    }

    /// A header and the "+" inside it are both hovered, as nested `.onHover`s are.
    @Test func nestedTargetsAreHoveredTogether() {
        let rows = Rows()
        rows.add("header", y: 0)
        rows.add("plus", y: 10, height: 20, x: 170, width: 20)

        rows.tracker.pointerMoved(to: CGPoint(x: 180, y: 20))
        #expect(Set(rows.take()) == ["+header", "+plus"])
        rows.tracker.pointerMoved(to: CGPoint(x: 50, y: 20))
        #expect(rows.take() == ["-plus"])
    }

    @Test func scrollingDropsHoverUntilTheListSettles() {
        let rows = Rows()
        rows.add("a", y: 0)
        rows.add("b", y: 40)
        rows.tracker.scrolled(to: 0) // the first reading is not a scroll
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 10))
        #expect(rows.take() == ["+a"])

        rows.tracker.scrolled(to: 40)
        #expect(rows.take() == ["-a"])
        // A move mid-scroll waits, and the row that scrolled under the pointer
        // wins when the list comes to rest.
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 20))
        #expect(rows.take().isEmpty)
        rows.tracker.currentPointer = { CGPoint(x: 10, y: 50) }
        rows.tracker.scrollSettled()
        #expect(rows.take() == ["+b"])
    }

    @Test func aContentHeightChangeAtTheSameOffsetIsNotAScroll() {
        let rows = Rows()
        rows.add("a", y: 0)
        rows.tracker.scrolled(to: 0)
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 10))
        rows.tracker.scrolled(to: 0)
        #expect(rows.take() == ["+a"])
    }

    /// A row mounting under a resting pointer (say, a group expanding) is hovered
    /// at once, and a row moved out from under it stops being hovered.
    @Test func registeringAndMovingFramesReconcilesWithThePointer() {
        let rows = Rows()
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 10))
        let id = rows.add("a", y: 0)
        #expect(rows.take() == ["+a"])

        rows.tracker.update(id, frame: CGRect(x: 0, y: 100, width: 200, height: 40)) { [unowned rows] in
            rows.log.append(($0 ? "+" : "-") + "a")
        }
        #expect(rows.take() == ["-a"])
    }

    /// A Space page parked off to the side must not react to a pointer over
    /// whatever its tracking area overlaps.
    @Test func aDisabledListDropsHoverAndIgnoresThePointer() {
        let rows = Rows()
        rows.add("a", y: 0)
        rows.tracker.pointerMoved(to: CGPoint(x: 10, y: 10))
        #expect(rows.take() == ["+a"])

        rows.tracker.isEnabled = false
        #expect(rows.take() == ["-a"])
        rows.tracker.pointerMoved(to: CGPoint(x: 20, y: 20))
        #expect(rows.take().isEmpty)
        rows.tracker.isEnabled = true
        #expect(rows.take() == ["+a"])
    }

    /// The real view stack, because the whole design rests on three coordinate
    /// systems agreeing: AppKit's window points, the tracking view's flipped
    /// ones, and SwiftUI's named space. A mismatch silently highlights the wrong
    /// row, and only once the list has scrolled.
    @Test func thePointerHoversTheRowUnderItAfterScrolling() throws {
        let tracker = SidebarHoverTracker(settleDelay: 0)
        let log = HoverLog()
        let list = ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<60, id: \.self) { index in
                    Color.clear.frame(height: 40).sidebarHover { if $0 { log.hovered = index } }
                }
            }
            .padding(.top, 10)
            .sidebarHoverTracking(tracker)
        }
        let hosting = NSHostingView(rootView: list.frame(width: 200, height: 400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        window.layoutIfNeeded()

        func viewsOf(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(viewsOf) }
        let all = viewsOf(hosting)
        let tracking = try #require(all.compactMap { $0 as? SidebarHoverTrackingBackingView }.first)
        let scroller = try #require(all.compactMap { $0 as? NSScrollView }.first)

        /// Moves the pointer to a height measured from the viewport's top.
        func pointer(atViewportY y: CGFloat) throws {
            log.hovered = nil
            window.layoutIfNeeded()
            let point = NSPoint(x: 100, y: window.frame.height - y)
            tracking.mouseMoved(with: try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            )))
        }

        // 10pt of padding, then 40pt rows: y=75 is in row 1.
        try pointer(atViewportY: 75)
        #expect(log.hovered == 1)

        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: 400))
        scroller.reflectScrolledClipView(scroller.contentView)
        // Lands in the document at 475, so row (475 - 10) / 40 = 11.
        window.layoutIfNeeded()
        tracker.scrollSettled()
        try pointer(atViewportY: 75)
        #expect(log.hovered == 11)
    }
}
