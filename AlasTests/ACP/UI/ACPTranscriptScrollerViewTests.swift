import AppKit
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptScrollerView")
struct ACPTranscriptScrollerViewTests {
    private func scroller(viewport: CGFloat = 800, document: CGFloat = 5000) -> ACPTranscriptScrollerView {
        let s = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: viewport))
        s.setDocumentHeight(document)
        s.layoutSubtreeIfNeeded()
        return s
    }

    @Test("document view is flipped so y grows downward")
    func flipped() {
        #expect(scroller().flippedDocumentView.isFlipped)
    }

    @Test("setScrollY moves the viewport and clamps to content")
    func programmaticScroll() {
        let s = scroller()
        s.setScrollY(1000)
        #expect(abs(s.scrollY - 1000) < 0.5)
        s.setScrollY(999_999)
        #expect(abs(s.scrollY - (5000 - s.viewportHeight)) < 1)
        s.setScrollY(-50)
        #expect(s.scrollY >= 0)
    }

    @Test("applyPrepend grows the document and keeps the viewport still")
    func prependCompensation() {
        let s = scroller()
        s.setScrollY(300)
        s.applyPrepend(delta: 700, newDocumentHeight: 5700)
        #expect(abs(s.scrollY - 1000) < 0.5)
        #expect(s.flippedDocumentView.frame.height == 5700)
        // The same content y-range is visible: distance from bottom unchanged.
        #expect(abs(s.distanceFromBottom - (5000 - s.viewportHeight - 300)) < 1)
    }

    /// `applyPrepend` used to assign the clip view's bounds origin without
    /// the clamp `setScrollY` applies, and `.removed` compensation routes a
    /// NEGATIVE delta through this same primitive. Empirically AppKit's own
    /// `NSClipView` already constrains the origin, so this held before the
    /// clamp was added too — these expectations pin the guarantee at OUR
    /// layer rather than leaving it to an AppKit implementation detail that
    /// a `constrainBoundsRect` override (or a clip-view swap) could remove.
    @Test("applyPrepend clamps its resulting offset exactly like setScrollY does")
    func prependClamps() {
        let s = scroller()
        s.setScrollY(300)
        s.applyPrepend(delta: -1000, newDocumentHeight: 4000)
        #expect(s.scrollY == 0)

        // The upper bound is clamped against the NEW document height, the
        // same expression `setScrollY` uses.
        s.applyPrepend(delta: 100_000, newDocumentHeight: 4000)
        #expect(abs(s.scrollY - (4000 - s.viewportHeight)) < 1)

        // A normal prepend (grow above, shift down by the same delta) is
        // untouched by the clamp.
        s.setScrollY(500)
        s.applyPrepend(delta: 700, newDocumentHeight: 4700)
        #expect(abs(s.scrollY - 1200) < 0.5)
    }

    @Test("scrollToBottom lands within tolerance of the bottom")
    func toBottom() {
        let s = scroller()
        s.scrollToBottom()
        #expect(s.distanceFromBottom < 1)
    }

    @Test("programmatic adjustments report isProgrammatic to onScroll")
    func programmaticReporting() {
        let s = scroller()
        var reports: [(y: CGFloat, programmatic: Bool)] = []
        s.onScroll = { _, newY, _, _, isProgrammatic in
            reports.append((newY, isProgrammatic))
        }
        s.setScrollY(400)
        #expect(reports.contains { abs($0.y - 400) < 0.5 && $0.programmatic })
        #expect(!reports.contains { !$0.programmatic })
    }

    @Test("logical native scroller commits only when AppKit sends its action")
    func logicalScrollerCommitsOnAction() throws {
        let s = scroller()
        let verticalScroller = try #require(s.verticalScroller)
        var committedValues: [Double] = []
        s.onLogicalScrollCommit = { committedValues.append($0) }

        #expect(!verticalScroller.isContinuous)
        s.setLogicalScrollerMetrics(.init(
            value: 0.25,
            knobProportion: 0.1,
            logicalViewportMessages: 10
        ))
        #expect(abs(verticalScroller.doubleValue - 0.25) < 0.000_001)
        #expect(abs(verticalScroller.knobProportion - 0.1) < 0.000_001)

        // A physical document move makes NSScrollView reflect its own
        // bounded range, but our logical metrics must win immediately.
        s.setScrollY(1000)
        #expect(abs(verticalScroller.doubleValue - 0.25) < 0.000_001)
        #expect(abs(verticalScroller.knobProportion - 0.1) < 0.000_001)

        // Knob tracking changes the control value without navigating. A
        // non-continuous NSScroller sends its action only when tracking ends.
        verticalScroller.doubleValue = 0.75
        #expect(committedValues.isEmpty)
        _ = verticalScroller.sendAction(verticalScroller.action, to: verticalScroller.target)
        #expect(committedValues == [0.75])
    }

    /// `onContentWidthChange` is the hook `ACPTranscriptScroller.Coordinator`
    /// uses to reconcile after a real width arrives from AppKit's own layout
    /// pass, without any accompanying SwiftUI model update (P1 finding,
    /// codex round 5). It must fire exactly once per genuine content-width
    /// change — including the very first non-zero width the view receives —
    /// and must NOT fire again for a layout pass at an unchanged width: a
    /// reconcile per layout pass would be a performance regression.
    @Test("onContentWidthChange fires once per genuine width change, not on a same-width layout pass")
    func contentWidthChangeFiresOnlyOnRealChange() {
        let s = ACPTranscriptScrollerView(frame: .zero)
        var fireCount = 0
        s.onContentWidthChange = { fireCount += 1 }

        // No layout pass has happened yet: no width to report.
        #expect(fireCount == 0)

        // First real width: fires.
        s.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.layoutSubtreeIfNeeded()
        #expect(fireCount == 1)

        // A no-op layout pass at the SAME width: does not re-fire.
        s.layoutSubtreeIfNeeded()
        #expect(fireCount == 1)

        // A genuinely different width: fires again.
        s.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        s.layoutSubtreeIfNeeded()
        #expect(fireCount == 2)
    }

    /// `onViewportHeightChange` is the hook `ACPTranscriptScroller
    /// .Coordinator` uses to re-run just the mount/relayout pass when the
    /// viewport's HEIGHT changes with no accompanying width change (P2
    /// finding, codex round 6) — see `ACPTranscriptScrollerView
    /// .onViewportHeightChange`'s doc comment. It must fire exactly once per
    /// genuine height-only change, must NOT fire again on a same-size layout
    /// pass, and must NOT fire when width changes too (that combined case is
    /// fully covered by `onContentWidthChange`'s own reconcile).
    @Test("onViewportHeightChange fires only on a height-only change, never together with a width change")
    func viewportHeightChangeFiresOnlyOnHeightOnlyChange() {
        let s = ACPTranscriptScrollerView(frame: .zero)
        var widthFireCount = 0
        var heightFireCount = 0
        s.onContentWidthChange = { widthFireCount += 1 }
        s.onViewportHeightChange = { heightFireCount += 1 }

        // First real size: bootstraps through the width hook only, matching
        // existing behavior — no height-only signal on the very first layout.
        s.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        s.layoutSubtreeIfNeeded()
        #expect(widthFireCount == 1)
        #expect(heightFireCount == 0)

        // Height-only change: fires the height hook, not the width hook.
        s.frame = NSRect(x: 0, y: 0, width: 600, height: 900)
        s.layoutSubtreeIfNeeded()
        #expect(widthFireCount == 1)
        #expect(heightFireCount == 1)

        // A no-op layout pass at the same size: neither re-fires.
        s.layoutSubtreeIfNeeded()
        #expect(widthFireCount == 1)
        #expect(heightFireCount == 1)

        // Width AND height changing together: only the width hook fires.
        s.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        s.layoutSubtreeIfNeeded()
        #expect(widthFireCount == 2)
        #expect(heightFireCount == 1)

        // Width-only change (height unchanged from the previous pass): only
        // the width hook fires, exactly like `contentWidthChangeFiresOnlyOnRealChange`.
        s.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        s.layoutSubtreeIfNeeded()
        #expect(widthFireCount == 3)
        #expect(heightFireCount == 1)
    }
}
