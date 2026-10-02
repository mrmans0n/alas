import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
private final class RecordingResponder: NSResponder {
    private(set) var receivedEvents: [NSEvent] = []
    override func scrollWheel(with event: NSEvent) { receivedEvents.append(event) }
    func clear() { receivedEvents.removeAll() }
}

private struct ThemeIDProbe: View {
    @Environment(\.theme) private var theme
    let onRead: (String) -> Void
    var body: some View {
        let _ = onRead(theme.id)
        Color.clear.frame(width: 10, height: 10)
    }
}

@MainActor
private final class HeightModel: ObservableObject {
    @Published var height: CGFloat = 40
}

private struct HeightModelContent: View {
    @ObservedObject var model: HeightModel
    var body: some View { Color.clear.frame(width: 500, height: model.height) }
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

    private func phasedEvent(
        deltaX: Int32 = 0, deltaY: Int32 = 0,
        phase: NSEvent.Phase = [], momentumPhase: NSEvent.Phase = []
    ) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0
        ))
        if !phase.isEmpty {
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventScrollPhase, value: cgScrollPhaseRawValue(for: phase))
        }
        if !momentumPhase.isEmpty {
            cgEvent.setIntegerValueField(CGEventField.scrollWheelEventMomentumPhase, value: cgMomentumPhaseRawValue(for: momentumPhase))
        }
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    private func cgScrollPhaseRawValue(for phase: NSEvent.Phase) -> Int64 {
        var rawValue: UInt32 = 0
        if phase.contains(.began) { rawValue |= CGScrollPhase.began.rawValue }
        if phase.contains(.changed) { rawValue |= CGScrollPhase.changed.rawValue }
        if phase.contains(.ended) { rawValue |= CGScrollPhase.ended.rawValue }
        if phase.contains(.cancelled) { rawValue |= CGScrollPhase.cancelled.rawValue }
        if phase.contains(.mayBegin) { rawValue |= CGScrollPhase.mayBegin.rawValue }
        return Int64(rawValue)
    }

    /// CG momentum phases use their own encoding (begin 1, continue 2, end 3).
    private func cgMomentumPhaseRawValue(for phase: NSEvent.Phase) -> Int64 {
        if phase.contains(.began) { return Int64(CGMomentumScrollPhase.begin.rawValue) }
        if phase.contains(.changed) { return Int64(CGMomentumScrollPhase.continuous.rawValue) }
        if phase.contains(.ended) { return Int64(CGMomentumScrollPhase.end.rawValue) }
        return 0
    }

    private func horizontalGesture() throws -> [NSEvent] {
        [
            try phasedEvent(phase: .began),
            try phasedEvent(deltaX: 20, phase: .changed),
            try phasedEvent(phase: .changed),
            try phasedEvent(deltaX: 1, deltaY: 3, phase: .changed),
            try phasedEvent(phase: .ended),
            try phasedEvent(momentumPhase: .began),
            try phasedEvent(deltaY: 4, momentumPhase: .changed),
            try phasedEvent(momentumPhase: .ended),
        ]
    }

    @Test("a vertical gesture is forwarded entirely, even after a late horizontal-dominant delta")
    func verticalGestureForwards() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let events = [
            try phasedEvent(phase: .began),
            try phasedEvent(deltaY: 20, phase: .changed),
            try phasedEvent(deltaX: 3, deltaY: 1, phase: .changed),
            try phasedEvent(phase: .ended),
            try phasedEvent(deltaX: 3, deltaY: 1, momentumPhase: .changed),
            try phasedEvent(momentumPhase: .ended),
        ]

        for event in events { scrollView.scrollWheel(with: event) }

        #expect(next.receivedEvents == events)
    }

    @Test("a horizontal gesture stays on the table from its first horizontal delta through momentum")
    func horizontalGestureStaysOnTable() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let events = try horizontalGesture()

        for event in events { scrollView.scrollWheel(with: event) }

        #expect(next.receivedEvents.isEmpty)
    }

    @Test("a vertical gesture's zero-delta start reaches the transcript first, in order")
    func verticalGestureDeliversBufferedStartInOrder() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let began = try phasedEvent(phase: .began)
        let changed = try phasedEvent(deltaY: 20, phase: .changed)
        let more = try phasedEvent(deltaY: 10, phase: .changed)

        scrollView.scrollWheel(with: began)
        #expect(next.receivedEvents.isEmpty)
        scrollView.scrollWheel(with: changed)
        scrollView.scrollWheel(with: more)

        #expect(next.receivedEvents == [began, changed, more])
    }

    @Test("a gesture cancelled before moving reaches the transcript at the cancel")
    func cancelledUndecidedGestureFlushes() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let mayBegin = try phasedEvent(phase: .mayBegin)
        let cancelled = try phasedEvent(phase: .cancelled)

        scrollView.scrollWheel(with: mayBegin)
        #expect(next.receivedEvents.isEmpty)
        scrollView.scrollWheel(with: cancelled)

        #expect(next.receivedEvents == [mayBegin, cancelled])
    }

    @Test("a gesture that ends without moving reaches the transcript, and a buffered start never leaks into the next gesture")
    func endedUndecidedGestureFlushesAndDoesNotLeak() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let began = try phasedEvent(phase: .began)
        let ended = try phasedEvent(phase: .ended)
        scrollView.scrollWheel(with: began)
        scrollView.scrollWheel(with: ended)
        #expect(next.receivedEvents == [began, ended])
        next.clear()

        // A start left buffered by an abandoned gesture is dropped by the next start.
        let abandoned = try phasedEvent(phase: .began)
        let nextBegan = try phasedEvent(phase: .began)
        let vertical = try phasedEvent(deltaY: 9, phase: .changed)
        scrollView.scrollWheel(with: abandoned)
        scrollView.scrollWheel(with: nextBegan)
        scrollView.scrollWheel(with: vertical)

        #expect(next.receivedEvents == [nextBegan, vertical])
    }

    @Test("a gesture that started outside the table stays with the transcript, and the next gesture is routed fresh")
    func gestureStartedElsewhereStaysWithTranscript() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        let events = [
            try phasedEvent(deltaX: 20, deltaY: 2, phase: .changed),
            try phasedEvent(deltaX: 15, phase: .changed),
            try phasedEvent(phase: .ended),
            try phasedEvent(momentumPhase: .began),
            try phasedEvent(deltaX: 8, momentumPhase: .changed),
            try phasedEvent(momentumPhase: .ended),
        ]

        for event in events { scrollView.scrollWheel(with: event) }
        #expect(next.receivedEvents == events)
        next.clear()

        for event in try horizontalGesture() { scrollView.scrollWheel(with: event) }
        #expect(next.receivedEvents.isEmpty)
    }

    @Test("a stray phased event after momentum ends is routed fresh")
    func momentumEndReleasesGesture() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        for event in try horizontalGesture() { scrollView.scrollWheel(with: event) }
        next.clear()

        let stray = try phasedEvent(deltaY: 20, phase: .changed)
        scrollView.scrollWheel(with: stray)

        #expect(next.receivedEvents == [stray])
    }

    @Test("a gesture that ends without momentum does not capture later wheel events")
    func endedWithoutMomentumDoesNotCaptureWheel() throws {
        let scrollView = scrollView(contentWidth: 900)
        let next = RecordingResponder()
        scrollView.nextResponder = next
        scrollView.scrollWheel(with: try phasedEvent(phase: .began))
        scrollView.scrollWheel(with: try phasedEvent(deltaX: 20, phase: .changed))
        scrollView.scrollWheel(with: try phasedEvent(phase: .ended))
        next.clear()

        let wheel = try wheelEvent(deltaX: 0, deltaY: 30)
        scrollView.scrollWheel(with: wheel)

        #expect(next.receivedEvents == [wheel])
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

    @Test("the representable follows content growth driven by a model, not by its inputs")
    func representableFollowsModelDrivenHeight() {
        let model = HeightModel()
        let host = NSHostingView(rootView:
            ACPHorizontalScrollView { HeightModelContent(model: model) }
                .frame(width: 300)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height == 40)

        model.height = 160
        // SwiftUI applies the model change on a later run-loop turn: poll with a deadline.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
            if host.fittingSize.height == 160 { break }
        }

        #expect(host.fittingSize.height == 160)
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
