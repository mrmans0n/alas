import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
private final class RecordingResponder: NSResponder {
    private(set) var receivedEvents: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { receivedEvents.append(event) }
}

private struct ThemeIDProbe: View {
    @Environment(\.theme) private var theme
    let onRead: (String) -> Void
    var body: some View {
        let _ = onRead(theme.id)
        Color.clear.frame(width: 10, height: 10)
    }
}

/// Wide markdown tables scroll sideways in an AppKit scroll view that keeps
/// only horizontal gestures, so vertical scrolling over a table reaches the
/// transcript through the ordinary responder chain.
@MainActor
@Suite("ACPHorizontalScrollView")
struct ACPHorizontalScrollViewTests {
    private func wheelEvent(deltaX: Int32, deltaY: Int32) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0
        ))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    /// A 300pt-wide scroll view hosting `contentWidth` x 60pt of content.
    private func scrollView(contentWidth: CGFloat) -> ACPHorizontalNSScrollView {
        let scrollView = ACPHorizontalNSScrollView()
        scrollView.setContent(AnyView(Color.clear.frame(width: contentWidth, height: 60)))
        scrollView.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }

    @Test("vertical wheel events go to the next responder", arguments: [(0, 30), (5, 30), (0, -30)])
    func verticalEventsForward(deltaX: Int32, deltaY: Int32) throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let event = try wheelEvent(deltaX: deltaX, deltaY: deltaY)

        scrollView.scrollWheel(with: event)

        #expect(next.receivedEvents == [event])
        #expect(scrollView.contentView.bounds.origin.x == 0)
    }

    // AppKit does not drive scrolling from a synthetic `NSEvent(cgEvent:)` (a
    // plain NSScrollView stays put too), so the scroll offset is not asserted.
    @Test("horizontal wheel events are not forwarded")
    func horizontalEventsStayHere() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next

        scrollView.scrollWheel(with: try wheelEvent(deltaX: -40, deltaY: 0))

        #expect(next.receivedEvents.isEmpty)
    }

    @Test("only horizontal-dominant deltas are kept", arguments: [
        (CGFloat(40), CGFloat(0), true), (-40, 5, true), (0, 30, false), (5, 30, false), (0, 0, false),
    ])
    func horizontalDominance(deltaX: CGFloat, deltaY: CGFloat, expected: Bool) {
        #expect(ACPHorizontalNSScrollView.isHorizontalDominant(deltaX: deltaX, deltaY: deltaY) == expected)
    }

    @Test("fitting height follows the content, including after an update")
    func fittingHeightFollowsContent() {
        let scrollView = ACPHorizontalNSScrollView()
        scrollView.setContent(AnyView(Color.clear.frame(width: 500, height: 60)))
        #expect(scrollView.contentFittingSize.height == 60)

        scrollView.setContent(AnyView(Color.clear.frame(width: 500, height: 140)))
        #expect(scrollView.contentFittingSize.height == 140)
    }

    @Test("the representable is as tall as its content and as wide as proposed")
    func representableSizing() {
        let host = NSHostingView(rootView:
            ACPHorizontalScrollView { Color.clear.frame(width: 900, height: 75) }
                .frame(width: 300)
        )
        #expect(host.fittingSize.height == 75)
        #expect(host.fittingSize.width == 300)
    }

    @Test("hosted content inherits the SwiftUI environment")
    func environmentReachesHostedContent() throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        var seenThemeID: String?
        let host = NSHostingView(rootView:
            ACPHorizontalScrollView { ThemeIDProbe { seenThemeID = $0 } }
                .environment(\.theme, theme)
                .frame(width: 300, height: 40)
        )
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        host.layoutSubtreeIfNeeded()

        #expect(seenThemeID == theme.id)
    }
}
