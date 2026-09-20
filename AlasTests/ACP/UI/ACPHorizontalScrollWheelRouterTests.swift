import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Scroll routing over transcript blocks that embed a horizontal SwiftUI
/// `ScrollView` (markdown tables, code blocks).
///
/// SwiftUI's internal scroll machinery consumes phase-bearing trackpad
/// gestures over these containers — vertical deltas never reach the
/// enclosing `ACPTranscriptScrollerView` through the responder chain, so
/// hovering a table froze transcript scrolling. The block wheel router
/// intercepts those gestures before dispatch and hands them to the
/// transcript scroller while leaving horizontal gestures (table sideways
/// scrolling) native.
///
/// The routing decision is driven directly through
/// `ACPBlockWheelRoutingView.handleScrollWheelEvent` with synthetic events:
/// `NSApp.sendEvent` rewrites nil-window event locations under the real
/// cursor, so window-bound synthetic delivery is not deterministic enough
/// to regression-test the monitor path. The monitor itself only binds the
/// event's window and cursor position before delegating to the same method.
@MainActor
@Suite(.serialized)
struct ACPHorizontalScrollWheelRouterTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    private func descendants<T: NSView>(of view: NSView, matching type: T.Type) -> [T] {
        view.subviews.flatMap { child in
            (child as? T).map { [$0] } ?? []
        } + view.subviews.flatMap { descendants(of: $0, matching: type) }
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

    private func phasedWheelEvent(
        deltaY: Int32,
        deltaX: Int32 = 0,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = []
    ) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0
        ))
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

    @MainActor
    private final class Fixture {
        let window: NSWindow
        let scroller: ACPTranscriptScrollerView
        let tiling = ACPTranscriptTilingController()
        let pool = ACPTranscriptRowHostingPool()
        let reconciler: ACPTranscriptScrollerReconciler

        init(markdown: String, rowCount: Int = 40, window: NSWindow) throws {
            self.window = window
            scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
            window.contentView = scroller
            scroller.layoutSubtreeIfNeeded()
            window.orderFront(nil)
            let theme = try Theme.loadBundled(id: "cool-slate")
            let specs = (0..<rowCount).map { index in
                ACPTranscriptRowSpec(id: "row\(index)", equalityToken: ACPRowEqualityToken(0)) {
                    AnyView(
                        ACPMarkdownText(raw: markdown)
                            .environment(\.theme, theme)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    )
                }
            }
            reconciler.apply(specs: specs, contentWidth: scroller.contentView.bounds.width, followsTail: false)
            scroller.onScroll = { [weak reconciler] _, _, _, _, isProgrammatic in
                guard let reconciler else { return }
                if !isProgrammatic { reconciler.noteUserScroll() }
                if !reconciler.isApplyingSpecs { reconciler.layoutMountedRowsForScroll() }
            }
        }

        func close() {
            scroller.onScroll = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    /// Parks the scroller at a safe offset and waits for the tiling's
    /// remeasure to converge, so neither scroll direction starts clamped and
    /// no in-flight height change pins the scroller at a clamp boundary.
    private func parkAndSettle(_ fixture: Fixture, at offset: CGFloat = 200) async throws {
        var lastHeight = fixture.scroller.contentHeight
        for _ in 0..<40 {
            autoreleasepool {
                fixture.window.layoutIfNeeded()
                fixture.window.contentView?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(10))
            let height = fixture.scroller.contentHeight
            if abs(height - lastHeight) < 0.5 { break }
            lastHeight = height
        }
        fixture.scroller.setScrollY(offset)
        fixture.reconciler.layoutMountedRowsForScroll()
        for _ in 0..<8 {
            autoreleasepool {
                fixture.window.layoutIfNeeded()
                fixture.window.contentView?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(fixture.scroller.scrollY - offset) < 1, "park must hold the requested offset")
    }

    /// Delivers a full trackpad two-finger gesture (.began → .changed×4 →
    /// .ended → momentum) through the router's decision seam at the given
    /// window point, then returns the scroller's scroll position after the
    /// gesture settles.
    private func deliverTrackpadGesture(
        through router: ACPBlockWheelRoutingView,
        at cursorInWindow: NSPoint,
        window: NSWindow
    ) async throws -> CGFloat {
        func deliver(_ event: NSEvent) throws {
            _ = router.handleScrollWheelEvent(event, cursorInWindow: cursorInWindow)
        }
        try deliver(phasedWheelEvent(deltaY: 0, phase: .began))
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<4 {
            try deliver(phasedWheelEvent(deltaY: 40, phase: .changed))
            try await Task.sleep(for: .milliseconds(20))
        }
        try deliver(phasedWheelEvent(deltaY: 0, phase: .ended))
        try await Task.sleep(for: .milliseconds(20))
        try deliver(phasedWheelEvent(deltaY: 0, momentumPhase: .began))
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<2 {
            try deliver(phasedWheelEvent(deltaY: 40, momentumPhase: .changed))
            try await Task.sleep(for: .milliseconds(20))
        }
        try deliver(phasedWheelEvent(deltaY: 0, momentumPhase: .ended))
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<6 {
            autoreleasepool {
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let scroller = router.transcriptScrollerForTesting else {
            Issue.record("router lost its transcript scroller")
            return 0
        }
        return scroller.scrollY
    }

    /// A point inside the router's own block, in window coordinates. The
    /// top padding band of the content (vertical cell padding is 6pt) is
    /// padding, never text.
    private func routerCursor(in router: ACPBlockWheelRoutingView) -> NSPoint {
        router.convert(NSPoint(x: router.bounds.midX, y: 20), to: nil)
    }

    private func visibleRouter(in fixture: Fixture) throws -> ACPBlockWheelRoutingView {
        try #require(
            descendants(of: fixture.scroller.flippedDocumentView, matching: ACPBlockWheelRoutingView.self)
                .first { view in
                    view.convert(view.bounds, to: fixture.scroller.flippedDocumentView)
                        .intersects(fixture.scroller.contentView.bounds)
                },
            "viewport must contain a mounted block wheel router"
        )
    }

    @Test("phased trackpad gesture over a markdown table scrolls the transcript")
    func trackpadGestureOverTableScrollsTranscript() async throws {
        let window = makeWindow()
        let fixture = try Fixture(
            markdown: """
            A **synthetic** transcript row with selectable prose and a table.

            | Name | Result | Detail |
            | --- | --- | --- |
            | Alpha | Ready | A deterministic table cell with enough text to wrap. |
            | Beta | Ready | Another table cell that exercises native text layout. |
            | Gamma | Ready | Scrolling this cell must scroll the outer transcript. |
            """,
            window: window
        )
        defer { fixture.close() }
        try await parkAndSettle(fixture)
        let router = try visibleRouter(in: fixture)
        let before = fixture.scroller.scrollY
        let after = try await deliverTrackpadGesture(through: router, at: routerCursor(in: router), window: window)
        #expect(abs(after - before) > 1, "a trackpad gesture over a markdown table must scroll the transcript")
    }

    @Test("phaseless wheel over a markdown table scrolls the transcript")
    func phaselessWheelOverTableScrollsTranscript() async throws {
        let window = makeWindow()
        let fixture = try Fixture(
            markdown: """
            A **synthetic** transcript row with selectable prose and a table.

            | Name | Result | Detail |
            | --- | --- | --- |
            | Alpha | Ready | A deterministic table cell with enough text to wrap. |
            | Beta | Ready | Another table cell that exercises native text layout. |
            | Gamma | Ready | Scrolling this cell must scroll the outer transcript. |
            """,
            window: window
        )
        defer { fixture.close() }
        try await parkAndSettle(fixture)
        let router = try visibleRouter(in: fixture)
        let cursor = routerCursor(in: router)
        let before = fixture.scroller.scrollY
        for _ in 0..<4 {
            _ = router.handleScrollWheelEvent(try phasedWheelEvent(deltaY: 40), cursorInWindow: cursor)
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<6 {
            autoreleasepool {
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let after = fixture.scroller.scrollY
        #expect(abs(after - before) > 1, "a mouse wheel over a markdown table must scroll the transcript")
    }

    @Test("vertical route consumed and horizontal route left to the block")
    func routerDecidesByDominantAxis() async throws {
        let window = makeWindow()
        let fixture = try Fixture(
            markdown: """
            Wide table:

            | A | B | C | D | E | F | G | H |
            | --- | --- | --- | --- | --- | --- | --- | --- |
            | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
            """,
            rowCount: 40,
            window: window
        )
        defer { fixture.close() }
        try await parkAndSettle(fixture)
        // Each event is routed through a freshly mounted router: routing a
        // vertical event scrolls the transcript, which can retire the row
        // the previously captured router belonged to.
        // Pure vertical event over the block: consumed (routed), not passed.
        let vertical = try phasedWheelEvent(deltaY: 40)
        let verticalRouter = try visibleRouter(in: fixture)
        #expect(verticalRouter.handleScrollWheelEvent(vertical, cursorInWindow: routerCursor(in: verticalRouter)) == nil)
        // Horizontal-dominant gesture over the block: left untouched for
        // the block's own scrolling (SwiftUI's horizontal scroll view).
        let horizontalStart = try phasedWheelEvent(deltaY: 0, deltaX: 40, phase: .began)
        let horizontalRouter = try visibleRouter(in: fixture)
        #expect(horizontalRouter.handleScrollWheelEvent(horizontalStart, cursorInWindow: routerCursor(in: horizontalRouter)) === horizontalStart)
        let horizontalChange = try phasedWheelEvent(deltaY: 0, deltaX: 40, phase: .changed)
        let changeRouter = try visibleRouter(in: fixture)
        #expect(changeRouter.handleScrollWheelEvent(horizontalChange, cursorInWindow: routerCursor(in: changeRouter)) === horizontalChange)
        // Ambiguous (equal-axis) gesture start: held until the axis
        // resolves, so neither scroller sees jitter.
        let ambiguousStart = try phasedWheelEvent(deltaY: 10, deltaX: 10, phase: .began)
        let ambiguousRouter = try visibleRouter(in: fixture)
        #expect(ambiguousRouter.handleScrollWheelEvent(ambiguousStart, cursorInWindow: routerCursor(in: ambiguousRouter)) == nil,
                "an ambiguous gesture start must be buffered, not dispatched")
    }

    @Test("events outside the router bounds dispatch normally")
    func outsideEventsPassThrough() async throws {
        let window = makeWindow()
        let fixture = try Fixture(
            markdown: """
            Wide table:

            | A | B | C | D | E | F | G | H |
            | --- | --- | --- | --- | --- | --- | --- | --- |
            | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
            """,
            rowCount: 40,
            window: window
        )
        defer { fixture.close() }
        try await parkAndSettle(fixture)
        let router = try #require(
            descendants(of: fixture.scroller.flippedDocumentView, matching: ACPBlockWheelRoutingView.self).first,
            "fixture must mount a router"
        )
        let event = try phasedWheelEvent(deltaY: 40, phase: .began)
        let outside = NSPoint(x: router.bounds.midX, y: router.bounds.maxY + 50)
        #expect(router.handleScrollWheelEvent(event, cursorInWindow: outside) === event)
    }

    @Test("phased trackpad gesture over a code block scrolls the transcript")
    func trackpadGestureOverCodeBlockScrollsTranscript() async throws {
        let window = makeWindow()
        let longCode = (0..<12).map { "let value\($0) = \($0) + someCall(\($0)) + moreTextOnThisLine" }
            .joined(separator: "\n")
        let fixture = try Fixture(
            markdown: """
            Prose line.

            ```swift
            \(longCode)
            ```
            """,
            window: window
        )
        defer { fixture.close() }
        try await parkAndSettle(fixture)
        let router = try visibleRouter(in: fixture)
        let before = fixture.scroller.scrollY
        let after = try await deliverTrackpadGesture(through: router, at: routerCursor(in: router), window: window)
        #expect(abs(after - before) > 1, "a trackpad gesture over a code block must scroll the transcript")
    }

    private func chain(from view: NSView?) -> [NSResponder] {
        guard var responder: NSResponder? = view else { return [] }
        var chain: [NSResponder] = []
        while let current = responder {
            chain.append(current)
            responder = current.nextResponder
            if chain.count > 20 { break }
        }
        return chain
    }
}
