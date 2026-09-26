import AppKit
import Observation
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("ACP transcript markdown convergence", .serialized)
struct ACPTranscriptScrollerConvergenceTests {
    @Test("same-width markdown measurement settles without suppressing content or width changes")
    func sameWidthMeasurementReachesFixedPoint() async throws {
        let theme = try Theme.loadBundled(id: "cool-slate")
        let content = ConvergenceMarkdownContent(raw: Self.markdown)
        let host = ACPTranscriptRowHostingView(
            rootView: AnyView(ConvergenceMarkdownRow(content: content, theme: theme))
        )
        let window = makeWindow()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        container.addSubview(host)
        defer {
            host.onIntrinsicSizeInvalidated = nil
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        var invalidations = 0
        host.onIntrinsicSizeInvalidated = { invalidations += 1 }
        let initialHeight = host.measuredHeight(forWidth: 600)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: initialHeight)
        window.orderFront(nil)
        try await settle(window)
        #expect(!descendants(of: host, matching: ACPMarkdownInlineNSTextView.self).isEmpty)

        let settledHeight = host.measuredHeight(forWidth: 600)
        try await settle(window)
        let beforeProbes = invalidations
        for _ in 0..<16 {
            let height = host.measuredHeight(forWidth: 600)
            #expect(abs(height - settledHeight) < 0.5)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(invalidations == beforeProbes,
                "unchanged measurement must not schedule another intrinsic-size measurement")

        // Change observed content without replacing the host or its root view.
        let beforeGrowth = invalidations
        content.raw += "\n\n" + String(repeating: "Streaming content must wrap and grow at the current width. ", count: 30)
        try await settle(window)
        let grownHeight = host.measuredHeight(forWidth: 600)
        #expect(grownHeight > settledHeight + 40)
        #expect(invalidations > beforeGrowth, "real content growth must still notify the row owner")

        let narrowHeight = host.measuredHeight(forWidth: 260)
        host.frame = NSRect(x: 0, y: 0, width: 260, height: narrowHeight)
        try await settle(window)
        #expect(host.measuredHeight(forWidth: 260) > grownHeight + 40)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: host.measuredHeight(forWidth: 600))
        try await settle(window)
        let restoredHeight = host.measuredHeight(forWidth: 600)
        #expect(abs(restoredHeight - grownHeight) < 1)
    }

    @Test("mounted streaming content updates document geometry without moving the reading anchor")
    func mountedStreamingGrowthPreservesReadingAnchor() async throws {
        let fixture = try ConvergenceScrollerFixture()
        defer { fixture.close() }
        let theme = try Theme.loadBundled(id: "cool-slate")
        let content = ConvergenceMarkdownContent(raw: Self.markdown)
        var specs = fixture.specs(0..<12)
        specs[0] = ACPTranscriptRowSpec(id: "row0", equalityToken: ACPRowEqualityToken(0)) {
            AnyView(ConvergenceMarkdownRow(content: content, theme: theme))
        }
        fixture.apply(specs)
        fixture.window.orderFront(nil)
        try await settle(fixture.window)
        fixture.scroller.setScrollY(500)
        fixture.reconciler.layoutMountedRowsForScroll()
        try await settle(fixture.window)
        let anchorBefore = try #require(fixture.tiling.row(withId: "row4")).minY - fixture.scroller.scrollY
        let heightBefore = fixture.scroller.contentHeight

        content.raw += "\n\n" + String(repeating: "Streaming content must grow above the reading position. ", count: 30)
        try await settle(fixture.window)

        #expect(fixture.scroller.contentHeight > heightBefore + 40)
        let anchorAfter = try #require(fixture.tiling.row(withId: "row4")).minY - fixture.scroller.scrollY
        #expect(abs(anchorAfter - anchorBefore) < 1)
    }

    @Test("head backfill and table wheels converge and release retired hosts and markdown views")
    func backfillAndTableWheelScrollingReleaseRetiredViews() async throws {
        let fixture = try ConvergenceScrollerFixture()
        defer { fixture.close() }
        let tracked = ConvergenceWeakViews()
        // The reconciler has no row clamp of its own; the window size only has
        // to make the backfilled document (windowRows + backfillRows rows, each
        // at least ~145pt including row spacing) much taller than one mount band
        // (viewport 400 + 2 * overscan 1200 = 2800pt). At 60 rows the 0.15, 0.8
        // and 0.3 scroll fractions below are >= ~3900pt apart, so each jump
        // retires the whole previous band; the disjointness guard asserts it.
        // Every inserted row is built and measured eagerly, so this size
        // dominates the test's cost.
        let windowRows = 45
        let backfillRows = windowRows / 3
        var head = 0
        var specs = fixture.specs(head..<(head + windowRows))
        fixture.apply(specs)
        fixture.window.orderFront(nil)
        try await settle(fixture.window)
        tracked.observe(fixture.scroller.flippedDocumentView)
        #expect(tracked.liveHostCount > 0)
        #expect(tracked.liveTextViewCount > 0)

        // Three backfills replace the entire original window.
        // Use an external test timeout: synchronous AppKit layout cannot be
        // interrupted by an in-process timer.
        for _ in 0..<3 {
            fixture.scroller.setScrollY(200)
            fixture.reconciler.layoutMountedRowsForScroll()
            let anchorID = "row\(head)"
            let anchorBefore = try #require(fixture.tiling.row(withId: anchorID)).minY - fixture.scroller.scrollY
            head -= backfillRows
            specs.insert(contentsOf: fixture.specs(head..<(head + backfillRows)), at: 0)
            fixture.apply(specs)
            try await settle(fixture.window)
            let anchorAfter = try #require(fixture.tiling.row(withId: anchorID)).minY - fixture.scroller.scrollY
            #expect(abs(anchorAfter - anchorBefore) < 1, "backfill must preserve the reading position")
            tracked.observe(fixture.scroller.flippedDocumentView)

            // Cross mount-band boundaries, then deliver real wheel events to
            // table cells inside their native horizontal scroll views.
            for fraction in [0.15, 0.8, 0.3] {
                let mountedBeforeJump = fixture.pool.mountedIds
                fixture.scroller.setScrollY((fixture.scroller.contentHeight - fixture.scroller.viewportHeight) * fraction)
                fixture.reconciler.layoutMountedRowsForScroll()
                try await settle(fixture.window)
                if fraction != 0.15 {
                    #expect(fixture.pool.mountedIds.isDisjoint(with: mountedBeforeJump),
                            "the document must be tall enough for each jump to retire the whole previous mount band")
                }
                tracked.observe(fixture.scroller.flippedDocumentView)
                let beforeWheel = fixture.scroller.scrollY
                try await sendTableGesture(in: fixture, deltaY: fraction == 0.8 ? 60 : -60)
                try await settle(fixture.window)
                #expect(abs(fixture.scroller.scrollY - beforeWheel) > 1,
                        "vertical wheels over a table must move the transcript")
                tracked.observe(fixture.scroller.flippedDocumentView)
            }

            // Match the bounded transcript window after its temporary backfill.
            specs = Array(specs.prefix(windowRows))
            fixture.apply(specs)
            try await settle(fixture.window)
            tracked.observe(fixture.scroller.flippedDocumentView)
            try await waitForRetiredViews(tracked, fixture: fixture)
            #expect(tracked.detachedLiveCount(in: fixture.scroller.flippedDocumentView) == 0,
                    "retired hosts and markdown views must release after settling")
            #expect(tracked.liveHostCount == fixture.pool.mountedIds.count)
            // Each fixture row has one paragraph and twelve table cells.
            #expect(tracked.liveTextViewCount <= fixture.pool.mountedIds.count * 13,
                    "live text views must stay bounded by mounted content, not scroll cycles")

            let height = fixture.scroller.contentHeight
            let y = fixture.scroller.scrollY
            let invalidations = fixture.invalidations.count
            for _ in 0..<8 {
                autoreleasepool {
                    fixture.reconciler.layoutMountedRows()
                    fixture.window.layoutIfNeeded()
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(abs(fixture.scroller.contentHeight - height) < 0.5)
            #expect(abs(fixture.scroller.scrollY - y) < 0.5)
            #expect(fixture.invalidations.count == invalidations,
                    "idle row layout must reach an intrinsic-invalidation fixed point")
        }

        // Keep the window, scroller, reconciler and pool alive while removing
        // rows. Otherwise teardown could conceal a pool or callback retention.
        fixture.apply([])
        try await waitForRetiredViews(tracked, fixture: fixture)
        #expect(fixture.pool.mountedIds.isEmpty)
        #expect(tracked.liveHostCount == 0)
        #expect(tracked.liveTextViewCount == 0)
    }

    @Test("invalidations from retired markdown hosts cannot remount offscreen rows")
    func retiredHostCannotRemountRow() async throws {
        let fixture = try ConvergenceScrollerFixture()
        defer { fixture.close() }
        // Enough rows (each >= ~145pt with spacing) that row0 falls outside the
        // bottom mount band (viewport 400 + overscan 1200 above it); the
        // `row0 == nil` expectation below fails if the fixture is too short.
        fixture.apply(fixture.specs(0..<30))
        fixture.window.orderFront(nil)
        try await settle(fixture.window)
        let retired = try #require(fixture.pool.mountedView(id: "row0"))
        fixture.scroller.scrollToBottom()
        fixture.reconciler.layoutMountedRowsForScroll()
        try await settle(fixture.window)
        #expect(fixture.pool.mountedView(id: "row0") == nil)
        let height = fixture.scroller.contentHeight
        let y = fixture.scroller.scrollY
        let invalidations = fixture.invalidations.count
        // AppKit can retain a detached hosting graph through a layout turn.
        retired.invalidateIntrinsicContentSize()
        #expect(fixture.invalidations.count == invalidations,
                "retiring the host must disarm its delayed invalidation callback")
        fixture.reconciler.remeasureRow(id: "row0")
        #expect(fixture.pool.mountedView(id: "row0") == nil,
                "remeasurement must not remount an offscreen row")
        #expect(fixture.scroller.contentHeight == height)
        #expect(fixture.scroller.scrollY == y)
    }

    private func sendTableGesture(in fixture: ConvergenceScrollerFixture, deltaY: Int32) async throws {
        for _ in 0..<4 {
            try autoreleasepool {
                let textView = try #require(
                    descendants(of: fixture.scroller.flippedDocumentView, matching: ACPMarkdownInlineNSTextView.self)
                        .first { view in
                            view.enclosingScrollView !== fixture.scroller
                                && view.enclosingScrollView != nil
                                && view.convert(view.bounds, to: fixture.scroller.flippedDocumentView)
                                    .intersects(fixture.scroller.contentView.bounds)
                        },
                    "the viewport must contain a real markdown table cell"
                )
                let event = try #require(CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: deltaY, wheel2: 0, wheel3: 0
                ))
                textView.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForRetiredViews(_ tracked: ConvergenceWeakViews, fixture: ConvergenceScrollerFixture) async throws {
        for _ in 0..<40 {
            if tracked.detachedLiveCount(in: fixture.scroller.flippedDocumentView) == 0 { return }
            try await Task.sleep(for: .milliseconds(25))
            autoreleasepool { fixture.window.layoutIfNeeded() }
        }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<8 {
            autoreleasepool {
                window.layoutIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    fileprivate static let markdown = """
    A **synthetic** transcript row with selectable prose and a table.

    | Name | Result | Detail |
    | --- | --- | --- |
    | Alpha | Ready | A deterministic table cell with enough text to wrap. |
    | Beta | Ready | Another table cell that exercises native text layout. |
    | Gamma | Ready | Scrolling this cell must scroll the outer transcript. |
    """
}

@MainActor
private func makeWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    return window
}

@MainActor
private func descendants<T: NSView>(of view: NSView, matching type: T.Type) -> [T] {
    view.subviews.flatMap { child in
        (child as? T).map { [$0] } ?? []
    } + view.subviews.flatMap { descendants(of: $0, matching: type) }
}

@MainActor
@Observable
private final class ConvergenceMarkdownContent {
    var raw: String
    init(raw: String) { self.raw = raw }
}

private struct ConvergenceMarkdownRow: View {
    let content: ConvergenceMarkdownContent
    let theme: Theme

    var body: some View {
        ACPMarkdownText(raw: content.raw)
            .environment(\.theme, theme)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class ConvergenceInvalidations {
    var count = 0
}

@MainActor
private final class ConvergenceScrollerFixture {
    let window = makeWindow()
    let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let tiling = ACPTranscriptTilingController()
    let pool = ACPTranscriptRowHostingPool()
    let reconciler: ACPTranscriptScrollerReconciler
    let invalidations = ConvergenceInvalidations()
    private let theme: Theme

    init() throws {
        theme = try Theme.loadBundled(id: "cool-slate")
        reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
        window.contentView = scroller
        scroller.layoutSubtreeIfNeeded()
        let originalInvalidation = pool.onRowIntrinsicSizeInvalidated
        let counter = invalidations
        pool.onRowIntrinsicSizeInvalidated = { id in
            counter.count += 1
            originalInvalidation?(id)
        }
        scroller.onScroll = { [weak reconciler] _, _, _, _, isProgrammatic in
            guard let reconciler else { return }
            if !isProgrammatic { reconciler.noteUserScroll() }
            if !reconciler.isApplyingSpecs { reconciler.layoutMountedRowsForScroll() }
        }
    }

    func specs(_ range: Range<Int>) -> [ACPTranscriptRowSpec] {
        let theme = theme
        return range.map { index in
            ACPTranscriptRowSpec(id: "row\(index)", equalityToken: ACPRowEqualityToken(0)) {
                AnyView(
                    ACPMarkdownText(raw: ACPTranscriptScrollerConvergenceTests.markdown)
                        .environment(\.theme, theme)
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        }
    }

    func apply(_ specs: [ACPTranscriptRowSpec]) {
        autoreleasepool {
            reconciler.apply(specs: specs, contentWidth: scroller.contentView.bounds.width, followsTail: false)
        }
    }

    func close() {
        scroller.onScroll = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }
}

@MainActor
private final class ConvergenceWeakViews {
    private final class Entry {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    var liveHostCount: Int { entries.values.filter { $0.view is ACPTranscriptRowHostingView }.count }
    var liveTextViewCount: Int { entries.values.filter { $0.view is ACPMarkdownInlineNSTextView }.count }

    func observe(_ document: NSView) {
        entries = entries.filter { $0.value.view != nil }
        for view in descendants(of: document, matching: NSView.self)
        where view is ACPTranscriptRowHostingView || view is ACPMarkdownInlineNSTextView {
            entries[ObjectIdentifier(view)] = Entry(view)
        }
    }

    func detachedLiveCount(in document: NSView) -> Int {
        entries.values.filter { entry in
            guard let view = entry.view else { return false }
            return !view.isDescendant(of: document)
        }.count
    }
}
