import AppKit
import Testing
@testable import Alas

@MainActor
private final class ACPMarkdownScrollRecordingResponder: NSResponder {
    private(set) var receivedEvents: [NSEvent] = []

    override func scrollWheel(with event: NSEvent) {
        receivedEvents.append(event)
    }
}

/// The transcript scroll beachball came from `ACPMarkdownInlineNSTextView`
/// re-running full TextKit layout on every `sizeThatFits` probe (SwiftUI's
/// StackLayout probes each row at several widths per placement pass and
/// re-probes on every scroll frame). These tests pin the memoization that
/// fixed it: repeated probes at a known width must hit the cache, and any
/// content change must invalidate it so heights never go stale.
@MainActor
struct ACPMarkdownInlineTextViewMeasurementCacheTests {
    private func makeTextView(_ text: String) -> ACPMarkdownInlineNSTextView {
        let textView = ACPMarkdownInlineNSTextView()
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        )
        return textView
    }

    private func makeScrollEvent(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) throws -> NSEvent {
        let cgEvent = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(deltaY),
                wheel2: Int32(deltaX),
                wheel3: 0
            )
        )
        if !phase.isEmpty {
            cgEvent.setIntegerValueField(
                CGEventField.scrollWheelEventScrollPhase,
                value: cgScrollPhaseRawValue(for: phase)
            )
        }
        if !momentumPhase.isEmpty {
            cgEvent.setIntegerValueField(
                CGEventField.scrollWheelEventMomentumPhase,
                value: cgScrollPhaseRawValue(for: momentumPhase)
            )
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

    @Test func repeatedSameWidthProbesHitTheCache() {
        let textView = makeTextView("The quick brown fox jumps over the lazy dog, several times, wrapping.")

        let first = textView.fittingSize(for: 200)
        let second = textView.fittingSize(for: 200)
        let third = textView.fittingSize(for: 200)

        #expect(first == second)
        #expect(second == third)
        #expect(textView.fittingComputationCountForTests == 1)
    }

    @Test func distinctWidthsEachComputeOnce() {
        let textView = makeTextView("The quick brown fox jumps over the lazy dog, several times, wrapping.")

        _ = textView.fittingSize(for: 200)
        _ = textView.fittingSize(for: 350)
        _ = textView.fittingSize(for: 200) // repeat → cache hit
        _ = textView.fittingSize(for: 350) // repeat → cache hit

        #expect(textView.fittingComputationCountForTests == 2)
    }

    @Test func invalidateForcesRecomputation() {
        let textView = makeTextView("Some wrapping text for the row.")

        _ = textView.fittingSize(for: 200)
        #expect(textView.fittingComputationCountForTests == 1)

        textView.invalidateFittingCache()
        _ = textView.fittingSize(for: 200)
        #expect(textView.fittingComputationCountForTests == 2)
    }

    @Test func naturalFittingSizeIsCached() {
        let textView = makeTextView("Some wrapping text for the row.")

        let first = textView.naturalFittingSize()
        let second = textView.naturalFittingSize()

        #expect(first == second)
        #expect(textView.fittingComputationCountForTests == 1)

        textView.invalidateFittingCache()
        _ = textView.naturalFittingSize()
        #expect(textView.fittingComputationCountForTests == 2)
    }

    @Test func cacheIsBoundedAndEvictsUnderWidthChurn() {
        let textView = makeTextView("Some wrapping text for the row.")

        // Fill the cache to its 16-entry limit with distinct widths.
        for offset in 0..<16 {
            _ = textView.fittingSize(for: 100 + CGFloat(offset))
        }
        #expect(textView.fittingComputationCountForTests == 16)

        // An earlier width is still cached — no recomputation.
        _ = textView.fittingSize(for: 100)
        #expect(textView.fittingComputationCountForTests == 16)

        // A 17th distinct width overflows the cap and clears the cache.
        _ = textView.fittingSize(for: 200)
        #expect(textView.fittingComputationCountForTests == 17)

        // The earlier width was evicted, so it now recomputes.
        _ = textView.fittingSize(for: 100)
        #expect(textView.fittingComputationCountForTests == 18)
    }

    @Test("only vertical-dominant wheel events are forwarded")
    func onlyVerticalDominantWheelEventsAreForwarded() {
        #expect(ACPMarkdownScrollRoutingState.isVerticalDominant(deltaX: 0, deltaY: 20))
        #expect(!ACPMarkdownScrollRoutingState.isVerticalDominant(deltaX: 20, deltaY: 0))
        #expect(!ACPMarkdownScrollRoutingState.isVerticalDominant(deltaX: 20, deltaY: 20))
    }

    @Test("scroll routing keeps the selected responder through phase-only endings")
    func scrollRoutingKeepsGestureResponderThroughPhaseOnlyEndings() {
        var vertical = ACPMarkdownScrollRoutingState()
        let verticalStart = vertical.shouldForward(
            deltaX: 0, deltaY: 20, phase: .began, momentumPhase: NSEvent.Phase()
        )
        let verticalEnd = vertical.shouldForward(
            deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: NSEvent.Phase()
        )
        #expect(verticalStart)
        #expect(verticalEnd)
        #expect(vertical.forwarding == true)

        var horizontal = ACPMarkdownScrollRoutingState()
        let horizontalStart = horizontal.shouldForward(
            deltaX: 20, deltaY: 0, phase: .began, momentumPhase: NSEvent.Phase()
        )
        let horizontalEnd = horizontal.shouldForward(
            deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: NSEvent.Phase()
        )
        #expect(!horizontalStart)
        #expect(!horizontalEnd)
        #expect(horizontal.forwarding == false)
    }

    @Test("scroll routing keeps forwarding through trackpad momentum")
    func scrollRoutingKeepsForwardingThroughMomentum() {
        var routing = ACPMarkdownScrollRoutingState()
        _ = routing.shouldForward(
            deltaX: 0, deltaY: 20, phase: .began, momentumPhase: NSEvent.Phase()
        )
        let momentumStart = routing.shouldForward(
            deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: .began
        )
        let momentumEnd = routing.shouldForward(
            deltaX: 0, deltaY: 0, phase: NSEvent.Phase(), momentumPhase: .ended
        )
        #expect(momentumStart)
        #expect(momentumEnd)
        #expect(routing.forwarding == nil)
    }

    @Test("scroll routing preserves the responder until momentum finishes")
    func scrollRoutingPreservesResponderUntilMomentumFinishes() {
        var routing = ACPMarkdownScrollRoutingState()
        _ = routing.shouldForward(
            deltaX: 0, deltaY: 20, phase: .began, momentumPhase: NSEvent.Phase()
        )
        let gestureEnd = routing.shouldForward(
            deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: NSEvent.Phase()
        )
        let momentumStart = routing.shouldForward(
            deltaX: 0, deltaY: 0, phase: NSEvent.Phase(), momentumPhase: .began
        )

        #expect(gestureEnd)
        #expect(momentumStart)
    }

    @Test("scroll routing waits for dominant axis before latching")
    func scrollRoutingWaitsForAxisBeforeLatching() {
        var routing = ACPMarkdownScrollRoutingState()

        let waitsForDominantAxis = !routing.shouldForward(
            deltaX: 10,
            deltaY: 10,
            phase: .began,
            momentumPhase: NSEvent.Phase()
        )
        #expect(waitsForDominantAxis)

        let followsDominantAxis = routing.shouldForward(
            deltaX: 0,
            deltaY: 20,
            phase: .changed,
            momentumPhase: NSEvent.Phase()
        )
        #expect(followsDominantAxis)

        let endsAfterDominantAxis = routing.shouldForward(
            deltaX: 0,
            deltaY: 0,
            phase: .ended,
            momentumPhase: NSEvent.Phase()
        )
        #expect(endsAfterDominantAxis)

        #expect(routing.forwarding == true)
    }

    @Test("vertical wheel events over Markdown text reach the transcript")
    func verticalWheelEventsReachTranscript() throws {
        let textView = makeTextView("Table cell")
        let transcriptResponder = ACPMarkdownScrollRecordingResponder()
        textView.nextResponder = transcriptResponder
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 20,
            wheel2: 0,
            wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))

        textView.scrollWheel(with: event)
        #expect(transcriptResponder.receivedEvents == [event])
    }

    @Test("ambiguous gesture starts are replayed once axis becomes vertical")
    func ambiguousGestureStartIsReplayedOnceAxisBecomesVertical() throws {
        let textView = makeTextView("Table cell")
        let transcriptResponder = ACPMarkdownScrollRecordingResponder()
        textView.nextResponder = transcriptResponder

        let ambiguousStart = try makeScrollEvent(
            deltaX: 10,
            deltaY: 10,
            phase: .began
        )
        textView.scrollWheel(with: ambiguousStart)

        let ambiguousChange = try makeScrollEvent(
            deltaX: 5,
            deltaY: 5,
            phase: .changed
        )
        textView.scrollWheel(with: ambiguousChange)

        let vertical = try makeScrollEvent(
            deltaX: 0,
            deltaY: 20,
            phase: .changed
        )
        textView.scrollWheel(with: vertical)

        #expect(textView.superScrollEventsForTests.isEmpty)
        #expect(transcriptResponder.receivedEvents.count == 3)
        #expect(transcriptResponder.receivedEvents[0] === ambiguousStart)
        #expect(transcriptResponder.receivedEvents[1] === ambiguousChange)
        #expect(transcriptResponder.receivedEvents[2] === vertical)
    }

    @Test("ambiguous gesture starts are replayed once axis becomes horizontal")
    func ambiguousGestureStartIsReplayedOnceAxisBecomesHorizontal() throws {
        let textView = makeTextView("Table cell")

        let ambiguousStart = try makeScrollEvent(
            deltaX: 10,
            deltaY: 10,
            phase: .began
        )
        textView.scrollWheel(with: ambiguousStart)

        let ambiguousChange = try makeScrollEvent(
            deltaX: 5,
            deltaY: 5,
            phase: .changed
        )
        textView.scrollWheel(with: ambiguousChange)

        let horizontal = try makeScrollEvent(
            deltaX: 20,
            deltaY: 0,
            phase: .changed
        )
        textView.scrollWheel(with: horizontal)

        #expect(textView.superScrollEventsForTests.count == 3)
        #expect(textView.superScrollEventsForTests[0] === ambiguousStart)
        #expect(textView.superScrollEventsForTests[1] === ambiguousChange)
        #expect(textView.superScrollEventsForTests[2] === horizontal)
    }
}
