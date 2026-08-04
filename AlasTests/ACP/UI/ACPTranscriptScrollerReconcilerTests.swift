import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite("ACPTranscriptScrollerReconciler diff")
struct ACPTranscriptScrollerReconcilerDiffTests {
    typealias Diff = ACPTranscriptScrollerReconciler.Diff

    @Test("identical id lists are unchanged")
    func unchanged() {
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b"], newIds: ["a", "b"]) == .unchanged)
    }

    @Test("new ids before the old head are an insert at index 0")
    func prepend() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["c", "d"], newIds: ["a", "b", "c", "d"])
            == .inserted(index: 0, count: 2)
        )
    }

    @Test("new ids after the old tail are an insert at the old list's end")
    func append() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b"], newIds: ["a", "b", "c"])
            == .inserted(index: 2, count: 1)
        )
    }

    @Test("ids removed from the middle are a removal, not a reset")
    func midListRemoval() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b", "c", "d"], newIds: ["a", "d"])
            == .removed(index: 1, count: 2)
        )
    }

    @Test("ids inserted in the middle are an insertion, not a reset")
    func midListInsertion() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b", "d", "e"], newIds: ["a", "b", "c", "d", "e"])
            == .inserted(index: 2, count: 1)
        )
    }

    @Test("changes at both ends simultaneously are a reset")
    func bothEndsChangingIsAReset() {
        // The generalized diff only classifies a SINGLE insertion or
        // removal point (found by trimming one common prefix and one
        // common suffix). Ids changing at both ends in the same update
        // don't reduce to either shape, so this is deliberately a reset —
        // simpler and rarer than the single-direction cases the fixed
        // synthetic rows (head pagination spinner, composer spacer) made
        // common once they stopped defeating incremental classification.
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["b"], newIds: ["a", "b", "c"])
            == .reset
        )
    }

    @Test("anything else is a reset")
    func reset() {
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b"], newIds: ["a", "c"]) == .reset)
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a"], newIds: ["z"]) == .reset)
    }

    @Test("empty transitions")
    func empties() {
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: [], newIds: ["a"]) == .inserted(index: 0, count: 1))
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: [], newIds: []) == .unchanged)
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a"], newIds: []) == .removed(index: 0, count: 1))
    }

    // MARK: fixed rows at both ends (the bug this generalization fixes)

    /// Mirrors `ACPTranscriptScroller.rowSpecs`'s actual shape: a fixed
    /// `__top_pagination__` row at index 0 and a fixed `__composer_spacer__`
    /// row at the tail, both unaffected by the mutation in between. Before
    /// the common-prefix/suffix generalization, having a fixed row at BOTH
    /// ends defeated the old "old ids are a contiguous run in new ids"
    /// check for every head-step and every append, forcing a `.reset` (full
    /// rebuild, no offset compensation) on what should have been a cheap
    /// incremental update — the bug CRITICAL #1 in the task-10 review fixed.
    @Test("a fixed row at both ends does not defeat head-step insertion")
    func headStepWithFixedRowsAtBothEnds() {
        let old = ["__top_pagination__", "m30", "m31", "m32", "__composer_spacer__"]
        let new = ["__top_pagination__", "m10", "m20", "m30", "m31", "m32", "__composer_spacer__"]
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: old, newIds: new) == .inserted(index: 1, count: 2))
    }

    @Test("a fixed trailing synthetic row does not defeat append insertion")
    func appendWithFixedTrailingSyntheticRow() {
        let old = ["m1", "m2", "__composer_spacer__"]
        let new = ["m1", "m2", "m3", "__composer_spacer__"]
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: old, newIds: new) == .inserted(index: 2, count: 1))
    }

    @Test("the streaming caret disappearing at the end of a turn is a removal, not a reset")
    func streamingCaretRemoval() {
        let old = ["m1", "m2", "__streaming_caret__", "__composer_spacer__"]
        let new = ["m1", "m2", "__composer_spacer__"]
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: old, newIds: new) == .removed(index: 2, count: 1))
    }
}

/// Counts how many times each row's SwiftUI content was actually built, so a
/// test can prove a code path did NOT construct (and therefore did not
/// measure) a hosting view for a row it already knew the height of.
@MainActor
private final class RowBuildCounter {
    private(set) var counts: [String: Int] = [:]
    func record(_ id: String) { counts[id, default: 0] += 1 }
    func count(_ id: String) -> Int { counts[id] ?? 0 }
}

@MainActor
@Suite("ACPTranscriptScrollerReconciler apply")
struct ACPTranscriptScrollerReconcilerApplyTests {
    private func makeStack() -> (ACPTranscriptScrollerReconciler, ACPTranscriptScrollerView, ACPTranscriptTilingController) {
        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tiling = ACPTranscriptTilingController()
        let pool = ACPTranscriptRowHostingPool()
        let reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
        return (reconciler, scroller, tiling)
    }

    private func spec(
        _ id: String, token: Int = 0, height: CGFloat = 100, keepsMountedOffscreen: Bool = false
    ) -> ACPTranscriptRowSpec {
        ACPTranscriptRowSpec(
            id: id,
            equalityToken: ACPRowEqualityToken(token),
            build: { AnyView(Color.clear.frame(height: height)) },
            keepsMountedOffscreen: keepsMountedOffscreen
        )
    }

    /// Like `makeStack`, but also hands back the pool so a test can reach
    /// into a mounted row's live hosting view directly (to simulate content
    /// growing in place, without going through another `apply()` call).
    private func makeStackWithPool() -> (
        ACPTranscriptScrollerReconciler, ACPTranscriptScrollerView,
        ACPTranscriptTilingController, ACPTranscriptRowHostingPool
    ) {
        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tiling = ACPTranscriptTilingController()
        let pool = ACPTranscriptRowHostingPool()
        let reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
        return (reconciler, scroller, tiling, pool)
    }

    /// Like `spec`, but records every `build()` invocation into `counter`.
    private func countingSpec(
        _ id: String, token: Int = 0, height: CGFloat = 100, counter: RowBuildCounter
    ) -> ACPTranscriptRowSpec {
        ACPTranscriptRowSpec(
            id: id,
            equalityToken: ACPRowEqualityToken(token),
            build: {
                counter.record(id)
                return AnyView(Color.clear.frame(height: height))
            }
        )
    }

    /// The on-screen y of a row: how far below the viewport's top edge it
    /// currently sits. Anchor preservation means this value survives a
    /// geometry replacement.
    private func screenOffset(
        of id: String, tiling: ACPTranscriptTilingController, scroller: ACPTranscriptScrollerView
    ) -> CGFloat {
        tiling.row(withId: id)!.minY - scroller.scrollY
    }

    /// Text content whose measured height genuinely depends on the width
    /// it's pinned at (unlike `spec`'s fixed-height `Color.clear`), so tests
    /// can tell a real re-measure at a new width apart from a stale one.
    private func wrappingSpec(_ id: String, token: Int = 0) -> ACPTranscriptRowSpec {
        ACPTranscriptRowSpec(
            id: id,
            equalityToken: ACPRowEqualityToken(token),
            build: {
                AnyView(
                    Text(String(repeating: "wrap me please ", count: 30))
                        .frame(maxWidth: .infinity, alignment: .leading)
                )
            }
        )
    }

    @Test("initial apply builds the document and mounts rows")
    func initialApply() {
        let (reconciler, scroller, tiling) = makeStack()
        reconciler.apply(specs: (0..<5).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        #expect(tiling.rowCount == 5)
        #expect(scroller.contentHeight == tiling.documentHeight)
        #expect(tiling.documentHeight > 0)
    }

    @Test("prepend keeps the viewport visually still")
    func prependStillViewport() {
        let (reconciler, scroller, tiling) = makeStack()
        reconciler.apply(specs: (10..<20).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        scroller.setScrollY(150)
        let bottomDistanceBefore = scroller.distanceFromBottom
        reconciler.apply(
            specs: (0..<20).map { spec("r\($0)") },
            contentWidth: 600, followsTail: false
        )
        #expect(tiling.rowCount == 20)
        #expect(abs(scroller.distanceFromBottom - bottomDistanceBefore) < 1)
        #expect(scroller.scrollY > 150)  // compensated upward by the prepended height
    }

    @Test("head-step insertion between fixed rows at both ends compensates end-to-end (no visible jump)")
    func headStepBetweenFixedSyntheticRowsCompensates() {
        // Regression test for CRITICAL #1 (task-10 review): with a fixed
        // row at BOTH ends of the spec list — matching
        // `ACPTranscriptScroller.rowSpecs`'s actual shape
        // (`__top_pagination__` first, `__composer_spacer__` last) — the
        // old contiguous-run diff always fell to `.reset` here, which never
        // compensates the scroll offset and made the transcript visibly
        // jump on every head-step. The generalized diff must classify this
        // as `.inserted`, and `apply()` must compensate exactly like a
        // pure prepend would.
        let (reconciler, scroller, tiling) = makeStack()
        func specsWithFixedEnds(messageIds: [String]) -> [ACPTranscriptRowSpec] {
            [spec("__top_pagination__")] + messageIds.map { spec($0) } + [spec("__composer_spacer__")]
        }
        reconciler.apply(
            specs: specsWithFixedEnds(messageIds: (30..<90).map { "m\($0)" }),
            contentWidth: 600, followsTail: false
        )
        scroller.setScrollY(800)
        let bottomDistanceBefore = scroller.distanceFromBottom

        reconciler.apply(
            specs: specsWithFixedEnds(messageIds: (10..<90).map { "m\($0)" }),
            contentWidth: 600, followsTail: false
        )

        #expect(tiling.rowCount == 82)   // top sentinel + 80 messages + spacer
        #expect(tiling.row(withId: "__top_pagination__") != nil)
        #expect(tiling.row(withId: "__composer_spacer__") != nil)
        // No visible jump: the viewport's distance from the bottom (and
        // hence what's on screen) is preserved, and the compensation moved
        // scrollY down by roughly the inserted content's height — exactly
        // the `prependStillViewport` assertions, now proven to also hold
        // when fixed rows bookend the list.
        #expect(abs(scroller.distanceFromBottom - bottomDistanceBefore) < 1)
        #expect(scroller.scrollY > 800)
    }

    @Test("append while following tail pins to the bottom")
    func appendFollowsTail() {
        let (reconciler, scroller, _) = makeStack()
        reconciler.apply(specs: (0..<10).map { spec("r\($0)") }, contentWidth: 600, followsTail: true)
        reconciler.apply(specs: (0..<12).map { spec("r\($0)") }, contentWidth: 600, followsTail: true)
        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("append while browsing does not move the viewport")
    func appendWhileBrowsing() {
        let (reconciler, scroller, _) = makeStack()
        reconciler.apply(specs: (0..<10).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        scroller.setScrollY(100)
        reconciler.apply(specs: (0..<12).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        #expect(abs(scroller.scrollY - 100) < 0.5)
    }

    @Test("reset replaces everything and follows the tail when asked")
    func resetToTail() {
        let (reconciler, scroller, tiling) = makeStack()
        reconciler.apply(specs: (0..<10).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        reconciler.apply(specs: (50..<60).map { spec("r\($0)") }, contentWidth: 600, followsTail: true)
        #expect(tiling.rowCount == 10)
        #expect(tiling.row(withId: "r50") != nil)
        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("only rows in the mount band have hosting views mounted")
    func mountBandLimitsMounting() {
        let (reconciler, scroller, tiling) = makeStack()
        // 200 rows x ~100pt ≈ 20,000pt document, 400pt viewport, 1200pt overscan.
        reconciler.apply(specs: (0..<200).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        scroller.setScrollY(10_000)
        reconciler.layoutMountedRows()
        let mounted = reconciler.mountedRowIdsForTesting
        #expect(mounted.count < 60)
        #expect(tiling.rowCount == 200)
        let band = tiling.mountBand(
            viewportMinY: 10_000, viewportHeight: 400,
            overscan: ACPTranscriptScrollerReconciler.overscan
        )
        #expect(mounted == Set(band.map { tiling.rowId(at: $0) }))
    }

    @Test("a row marked keepsMountedOffscreen stays mounted far outside the band; an ordinary row at the same position does not")
    func keepsMountedOffscreenSurvivesOutsideBand() {
        // Regression test for the P2 finding (codex round 4): scrolling a
        // pending `ACPUserInputPrompt` more than the overscan distance away
        // used to release its hosting view and, with it, the form data the
        // user had already entered. A spec opted into `keepsMountedOffscreen`
        // must stay in the pool's mounted set regardless of the viewport,
        // while an ordinary row right next to it is released exactly as
        // before.
        let (reconciler, scroller, tiling, pool) = makeStackWithPool()
        var specs = (0..<200).map { spec("r\($0)") }
        specs[0] = spec("kept", keepsMountedOffscreen: true)
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        scroller.setScrollY(10_000)
        reconciler.layoutMountedRows()

        let mounted = reconciler.mountedRowIdsForTesting
        let band = tiling.mountBand(
            viewportMinY: 10_000, viewportHeight: 400,
            overscan: ACPTranscriptScrollerReconciler.overscan
        )
        let ordinaryBandIds = Set(band.map { tiling.rowId(at: $0) })

        // "kept" sits at row 0, far outside the band computed at scrollY
        // 10,000 — proving the exemption, not the ordinary band, is what
        // keeps it mounted.
        #expect(!band.contains(tiling.index(ofId: "kept")!))
        #expect(mounted.contains("kept"))
        // The exemption is additive, not a widening of the band itself: the
        // mounted set is exactly the band plus the one exempted row, and the
        // kept row is positioned at its real tiled coordinates.
        #expect(mounted == ordinaryBandIds.union(["kept"]))
        // Row 0's real tiled position, unmoved by the exemption — a kept row
        // is placed like any other mounted row, not at an arbitrary spot,
        // and its live hosting view's frame reflects exactly that position.
        let keptLayout = tiling.row(withId: "kept")!
        #expect(keptLayout.minY == 24)
        let keptView = pool.mountedView(id: "kept")
        #expect(keptView?.frame.minY == keptLayout.minY)
        #expect(keptView?.frame.height == keptLayout.height)
        #expect(keptView?.superview === scroller.flippedDocumentView)

        // An ordinary row at a nearby out-of-band position ("r1", right next
        // to "kept") is released exactly as before.
        #expect(!mounted.contains("r1"))
    }

    @Test("keepsMountedOffscreen survives a width-settled reset, which also unmounts ordinary off-band rows")
    func keepsMountedOffscreenSurvivesWidthSettledReset() async throws {
        // The other route to the same data loss: `.reset` (here, the
        // width-settle reset a window resize schedules) re-measures via
        // `performReset` and then runs the ordinary `layoutMountedRows()`
        // pass — the SAME `pool.releaseAll(except: keep)` call site the
        // scroll-driven case goes through, not a separate unconditional
        // `pool.releaseAll()`. Because the fix lives in `performLayoutPass`
        // itself, both routes are covered by the same `keep` union.
        let (reconciler, scroller, tiling) = makeStack()
        var specs = (0..<200).map { spec("r\($0)") }
        specs[0] = spec("kept", keepsMountedOffscreen: true)
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        scroller.setScrollY(10_000)
        reconciler.layoutMountedRows()
        #expect(reconciler.mountedRowIdsForTesting.contains("kept"))

        // A resize while browsing: same ids, narrower width. The coalesced
        // path applies immediately (bounded interim work); the full
        // re-measure-everything reset lands after the debounce settles.
        reconciler.apply(specs: specs, contentWidth: 300, followsTail: false)

        let graceNanoseconds = UInt64(
            (ACPTranscriptScrollerReconciler.widthChangeSettleInterval + 0.4) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: graceNanoseconds)

        // The settle reset ran (proves this isn't vacuous) and released the
        // ordinary off-band rows exactly as before, but "kept" is still
        // mounted at its real (re-tiled) position.
        let mounted = reconciler.mountedRowIdsForTesting
        #expect(!mounted.contains("r1"))
        #expect(mounted.contains("kept"))
        let band = tiling.mountBand(
            viewportMinY: scroller.scrollY, viewportHeight: scroller.viewportHeight,
            overscan: ACPTranscriptScrollerReconciler.overscan
        )
        #expect(!band.contains(tiling.index(ofId: "kept")!))
    }

    @Test("apply with a non-positive width is deferred rather than collapsing the document")
    func nonPositiveWidthIsDeferred() {
        let (reconciler, scroller, tiling) = makeStack()
        reconciler.apply(specs: (0..<5).map { spec("r\($0)") }, contentWidth: 0, followsTail: false)
        #expect(tiling.rowCount == 0)
        #expect(scroller.contentHeight == 0)

        reconciler.apply(specs: (0..<5).map { spec("r\($0)") }, contentWidth: -10, followsTail: false)
        #expect(tiling.rowCount == 0)

        // A later call with a real width behaves as a normal initial apply.
        reconciler.apply(specs: (0..<5).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        #expect(tiling.rowCount == 5)
        #expect(tiling.documentHeight > 0)
    }

    @Test("remeasureRow re-measures a mounted row in place and updates the document")
    func remeasureRowUpdatesHeight() {
        let (reconciler, scroller, tiling, pool) = makeStackWithPool()
        let specs = (0..<10).map { spec("r\($0)") }
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        let heightBefore = tiling.row(withId: "r0")!.height

        // Simulate the row's SwiftUI content growing in place (e.g. a
        // streaming row), independent of any `apply()` call: replace the
        // mounted view's content directly and rely on `remeasureRow` — the
        // callback path `pool.onRowIntrinsicSizeInvalidated` exists for.
        let (view0, _) = pool.view(for: specs[0])
        view0.updateRootView(AnyView(Color.clear.frame(height: 250)))
        reconciler.remeasureRow(id: "r0")

        #expect(tiling.row(withId: "r0")!.height == 250)
        #expect(tiling.row(withId: "r0")!.height != heightBefore)
        #expect(scroller.contentHeight == tiling.documentHeight)
    }

    @Test("remeasureRow compensates the viewport when the grown row is entirely above it")
    func remeasureRowCompensatesAboveViewport() {
        let (reconciler, scroller, tiling, pool) = makeStackWithPool()
        let specs = (0..<10).map { spec("r\($0)") }
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        // r0 spans minY 24..124; scrolling to 500 puts it entirely above.
        scroller.setScrollY(500)
        let scrollYBefore = scroller.scrollY

        let (view0, _) = pool.view(for: specs[0])
        view0.updateRootView(AnyView(Color.clear.frame(height: 250)))
        reconciler.remeasureRow(id: "r0")

        #expect(tiling.row(withId: "r0")!.height == 250)
        #expect(scroller.scrollY > scrollYBefore)
    }

    @Test("remeasureRow re-pins to the bottom when a mounted tail row grows while following the tail")
    func remeasureRowRepinsToBottomWhileFollowingTail() {
        // Headline scenario: streaming while pinned to the bottom stays
        // pinned. The last row ("r9") growing in place (an image finishing
        // its load, an expandable row toggling) is never "entirely above
        // the viewport" while tail-following, so `updateHeight`'s
        // compensation is correctly zero — the document grows underneath a
        // scroll offset that doesn't move on its own. Without the fix, the
        // viewport is left short of the new bottom by the growth amount.
        let (reconciler, scroller, tiling, pool) = makeStackWithPool()
        let specs = (0..<10).map { spec("r\($0)") }
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: true)
        #expect(scroller.distanceFromBottom < 1)

        let (lastView, _) = pool.view(for: specs[9])
        lastView.updateRootView(AnyView(Color.clear.frame(height: 250)))
        reconciler.remeasureRow(id: "r9")

        #expect(tiling.row(withId: "r9")!.height == 250)
        #expect(scroller.distanceFromBottom < 1)
        #expect(scroller.contentHeight == tiling.documentHeight)
    }

    @Test("remeasureRow does not move the viewport when a tail row grows while browsing (not following the tail)")
    func remeasureRowDoesNotRepinWhileBrowsing() {
        // Guard against the fix over-reaching: a user who has scrolled away
        // from the tail must not be fought back to the bottom just because
        // some row's content happened to change size.
        let (reconciler, scroller, tiling, pool) = makeStackWithPool()
        let specs = (0..<10).map { spec("r\($0)") }
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        scroller.setScrollY(0)
        let scrollYBefore = scroller.scrollY

        let (lastView, _) = pool.view(for: specs[9])
        lastView.updateRootView(AnyView(Color.clear.frame(height: 250)))
        reconciler.remeasureRow(id: "r9")

        #expect(tiling.row(withId: "r9")!.height == 250)
        #expect(abs(scroller.scrollY - scrollYBefore) < 0.5)
    }

    @Test("remeasureRow is a no-op for an id that isn't currently tracked")
    func remeasureRowUnknownIdNoOps() {
        let (reconciler, _, tiling, _) = makeStackWithPool()
        reconciler.apply(specs: (0..<3).map { spec("r\($0)") }, contentWidth: 600, followsTail: false)
        let heightBefore = tiling.documentHeight
        reconciler.remeasureRow(id: "does-not-exist")
        #expect(tiling.documentHeight == heightBefore)
    }

    @Test("a genuine reset with overlapping ids and changed content does not corrupt geometry via reentrant remeasure")
    func resetWithOverlappingIdsDoesNotCorrupt() {
        let (reconciler, scroller, tiling) = makeStack()
        // Old: r5...r14. New: r0...r9 — overlaps at r5...r9, but the old
        // head "r5" isn't a contiguous prefix of the new list (length
        // mismatch), so `diff` classifies this as `.reset`, not a
        // prepend/append. The overlapping ids get a different token, so
        // they're genuinely different content reusing the same id.
        reconciler.apply(specs: (5..<15).map { spec("r\($0)", token: 0) }, contentWidth: 600, followsTail: false)
        scroller.setScrollY(300)
        reconciler.apply(specs: (0..<10).map { spec("r\($0)", token: 1) }, contentWidth: 600, followsTail: false)

        #expect(tiling.rowCount == 10)
        for id in (0..<10).map({ "r\($0)" }) {
            #expect(tiling.row(withId: id) != nil)
        }
        #expect(tiling.documentHeight > 0)
        // No stray compensation from a reentrant remeasure operating against
        // the old (pre-reset) tiling geometry. `.reset` now re-anchors the
        // offset to the row that was at the viewport top (final-review
        // CRITICAL 1) — here "r7", which sat at minY 260 with scrollY 300,
        // i.e. 40pt into the row — and nothing else may move it. In the new
        // (shorter) geometry that target lands past the document's end, so
        // the expected value is the anchor clamped to the scrollable range,
        // exactly what `setScrollY` produces.
        let anchorRowMinY = tiling.row(withId: "r7")!.minY
        let expected = min(anchorRowMinY + 40, max(0, tiling.documentHeight - scroller.viewportHeight))
        #expect(abs(scroller.scrollY - expected) < 0.5)
    }

    // MARK: reset preserves the scroll anchor (final-review CRITICAL 1)

    /// The real spec shape of the FINAL head step: once `visibleHead` reaches
    /// 0 the `__top_pagination__` row at index 0 disappears in the very same
    /// update that inserts the last block of older messages. Ids change at
    /// both ends at once, so prefix/suffix trimming can't classify it and it
    /// falls to `.reset` — the one diff case that used to replace all
    /// geometry while leaving `scrollY` at its old numeric value, jumping the
    /// transcript at exactly the moment head pagination is supposed to feel
    /// seamless.
    private func finalHeadStepSpecs() -> (old: [ACPTranscriptRowSpec], new: [ACPTranscriptRowSpec]) {
        (
            old: [spec("__top_pagination__", height: 14)]
                + (30..<90).map { spec("m\($0)") }
                + [spec("__composer_spacer__", height: 220)],
            new: (0..<90).map { spec("m\($0)") }
                + [spec("__composer_spacer__", height: 220)]
        )
    }

    @Test("the final head step is a reset, and the reset keeps the top-visible row visually put")
    func resetPreservesScrollAnchor() {
        let (reconciler, scroller, tiling) = makeStack()
        let (old, new) = finalHeadStepSpecs()
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: old.map(\.id), newIds: new.map(\.id)) == .reset
        )

        reconciler.apply(specs: old, contentWidth: 600, followsTail: false)
        scroller.setScrollY(800)
        let anchorId = tiling.topVisibleRowId(viewportMinY: scroller.scrollY)!
        #expect(!anchorId.hasPrefix("__"))
        let before = screenOffset(of: anchorId, tiling: tiling, scroller: scroller)

        reconciler.apply(specs: new, contentWidth: 600, followsTail: false)

        #expect(tiling.row(withId: anchorId) != nil)
        #expect(abs(screenOffset(of: anchorId, tiling: tiling, scroller: scroller) - before) < 1)
    }

    @Test("the reset anchor skips the synthetic row that the reset itself deletes")
    func resetAnchorSkipsSyntheticRows() {
        // The head pagination spinner occupies row 0 (minY 24, maxY 38), so
        // any scrollY < 38 makes it the topmost VISIBLE row — and that
        // position, the top-of-history bounce, is precisely what triggers
        // the final head step, which deletes that very row. Anchoring to it
        // means restoration finds nothing to aim at and silently no-ops,
        // leaving the original hard jump exactly where it was reported.
        let (reconciler, scroller, tiling) = makeStack()
        let (old, new) = finalHeadStepSpecs()
        reconciler.apply(specs: old, contentWidth: 600, followsTail: false)
        scroller.setScrollY(30)
        #expect(tiling.topVisibleRowId(viewportMinY: scroller.scrollY) == "__top_pagination__")
        // The anchor row starts BELOW the scroll position here, so its
        // offset within the row is negative — which must still restore
        // exactly, not be floored to zero.
        #expect(tiling.row(withId: "m30")!.minY > scroller.scrollY)
        let before = screenOffset(of: "m30", tiling: tiling, scroller: scroller)

        reconciler.apply(specs: new, contentWidth: 600, followsTail: false)

        #expect(abs(screenOffset(of: "m30", tiling: tiling, scroller: scroller) - before) < 1)
    }

    @Test("the restored anchor offset is capped at the anchor row's new height")
    func resetClampsAnchorOffsetToRowHeight() {
        let (reconciler, scroller, tiling) = makeStack()
        let old = [spec("__top_pagination__", height: 14), spec("m0", token: 0, height: 1000)]
            + (1..<6).map { spec("m\($0)") }
            + [spec("__composer_spacer__", height: 220)]
        reconciler.apply(specs: old, contentWidth: 600, followsTail: false)
        #expect(tiling.row(withId: "m0")!.minY == 56)
        scroller.setScrollY(600)
        #expect(tiling.topVisibleRowId(viewportMinY: scroller.scrollY) == "m0")

        // Ids change at both ends at once (the head sentinel replaced by a
        // real row) so this is a `.reset`, and the anchor row itself
        // collapses from 1000pt to 100pt in the same update.
        let new = [spec("mA"), spec("m0", token: 1, height: 100)]
            + (1..<6).map { spec("m\($0)") }
            + [spec("__composer_spacer__", height: 220)]
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: old.map(\.id), newIds: new.map(\.id)) == .reset
        )
        reconciler.apply(specs: new, contentWidth: 600, followsTail: false)

        let row = tiling.row(withId: "m0")!
        #expect(row.height == 100)
        // The offset within the row was 544pt; unclamped it would land far
        // past a row that is now only 100pt tall. The viewport top can be at
        // most the anchor row's bottom edge.
        #expect(abs(scroller.scrollY - row.maxY) < 0.5)
    }

    @Test("a reset while following the tail still pins to the bottom rather than restoring an anchor")
    func resetWhileFollowingTailStillPinsToBottom() {
        let (reconciler, scroller, _) = makeStack()
        let (old, new) = finalHeadStepSpecs()
        reconciler.apply(specs: old, contentWidth: 600, followsTail: true)
        reconciler.apply(specs: new, contentWidth: 600, followsTail: true)
        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("the width-settled reset preserves the scroll anchor")
    func widthSettledResetPreservesScrollAnchor() async throws {
        let (reconciler, scroller, tiling) = makeStack()
        let specs = (0..<200).map { wrappingSpec("r\($0)") }
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        scroller.setScrollY(2000)

        // A resize while browsing history: same ids, narrower width. The
        // coalesced path applies immediately; the expensive full re-measure
        // lands 150ms later and used to teleport the viewport.
        reconciler.apply(specs: specs, contentWidth: 300, followsTail: false)
        let anchorId = tiling.topVisibleRowId(viewportMinY: scroller.scrollY)!
        let before = screenOffset(of: anchorId, tiling: tiling, scroller: scroller)

        let graceNanoseconds = UInt64(
            (ACPTranscriptScrollerReconciler.widthChangeSettleInterval + 0.4) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: graceNanoseconds)

        #expect(abs(screenOffset(of: anchorId, tiling: tiling, scroller: scroller) - before) < 1)
    }

    @Test("a width-settled reset preserves the viewport position when its top sits inside the synthetic tail region")
    func widthSettledResetPreservesPositionInSyntheticTailRegion() async throws {
        // The forward-only anchor walk in `captureScrollAnchor` finds the
        // first NON-synthetic row at or below the viewport top. When the
        // viewport top is already past every message row — parked over a
        // queued bubble, say — there is no following message row to walk
        // to, and the old behavior returned nil, silently skipping
        // restoration. A width-settled reset still reflows the wrapping
        // message rows ABOVE the viewport, which must not visibly drag the
        // synthetic tail content the user is looking at.
        let (reconciler, scroller, tiling) = makeStack()
        // The composer spacer is made much taller than its real ~220pt so
        // the tail region below "__queue_2__" comfortably exceeds the
        // 400pt viewport height — otherwise `setScrollY`'s clamp (which
        // never lets the viewport scroll past the document's end) would
        // pull the requested offset back up onto a message row, defeating
        // the point of parking the viewport inside the synthetic tail.
        let specs = (0..<50).map { wrappingSpec("m\($0)") }
            + [
                spec("__queue_1__", height: 50), spec("__queue_2__", height: 50),
                spec("__composer_spacer__", height: 600),
            ]
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)
        let m0HeightBefore = tiling.row(withId: "m0")!.height

        // Park the viewport top inside the synthetic tail region: every row
        // from here through the document end is synthetic.
        let queueRowMinY = tiling.row(withId: "__queue_2__")!.minY
        scroller.setScrollY(queueRowMinY + 10)
        #expect(tiling.topVisibleRowId(viewportMinY: scroller.scrollY) == "__queue_2__")
        let distanceBefore = scroller.distanceFromBottom

        // A resize while browsing the synthetic tail: same ids, narrower
        // width. The coalesced path applies immediately; the full
        // re-measure lands 150ms later.
        reconciler.apply(specs: specs, contentWidth: 300, followsTail: false)

        let graceNanoseconds = UInt64(
            (ACPTranscriptScrollerReconciler.widthChangeSettleInterval + 0.4) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: graceNanoseconds)

        // The message rows above genuinely reflowed (proves the assertion
        // below isn't vacuously true), and the viewport's distance from the
        // document's bottom edge — the synthetic tail's natural reference
        // point — is unchanged.
        #expect(tiling.row(withId: "m0")!.height != m0HeightBefore)
        #expect(abs(scroller.distanceFromBottom - distanceBefore) < 1)
    }

    // MARK: reset does not re-measure rows it already knows (final-review CRITICAL 2)

    @Test("a reset at unchanged width does not rebuild rows whose content is unchanged")
    func resetReusesKnownHeights() {
        let counter = RowBuildCounter()
        let (reconciler, scroller, tiling) = makeStack()
        let old = [countingSpec("__top_pagination__", height: 14, counter: counter)]
            + (30..<90).map { countingSpec("m\($0)", counter: counter) }
            + [countingSpec("__composer_spacer__", height: 220, counter: counter)]
        reconciler.apply(specs: old, contentWidth: 600, followsTail: false)
        scroller.setScrollY(800)
        reconciler.layoutMountedRows()

        // "m89" sits ~10,000pt down a ~7,300pt-tall document's worth of rows
        // below the viewport: far outside the mount band, so it has no live
        // hosting view and its measured height is already on record.
        #expect(!reconciler.mountedRowIdsForTesting.contains("m89"))
        let offBandBuildsBefore = counter.count("m89")
        #expect(offBandBuildsBefore == 1)

        let new = (0..<90).map { countingSpec("m\($0)", counter: counter) }
            + [countingSpec("__composer_spacer__", height: 220, counter: counter)]
        reconciler.apply(specs: new, contentWidth: 600, followsTail: false)

        // The reset must carry "m89"'s known height forward rather than
        // constructing an NSHostingView for it and measuring it again — the
        // whole point being that a reset costs O(new rows), not O(window).
        #expect(counter.count("m89") == offBandBuildsBefore)
        // ...while genuinely new rows are of course measured.
        #expect(counter.count("m0") >= 1)
        #expect(tiling.rowCount == 91)
        #expect(scroller.contentHeight == tiling.documentHeight)
    }

    @Test("an id-change reset inside the settle window does not cancel the pending width settle")
    func idChangeResetDoesNotCancelPendingWidthSettle() async throws {
        let (reconciler, scroller, tiling) = makeStack()
        let rows = (0..<200).map { wrappingSpec("r\($0)") }
        reconciler.apply(specs: rows, contentWidth: 600, followsTail: false)
        scroller.setScrollY(0)
        let offBandHeightWide = tiling.row(withId: "r199")!.height

        // A resize: same ids, so this coalesces and schedules the settle
        // reset rather than re-measuring everything now.
        reconciler.apply(specs: rows, contentWidth: 300, followsTail: false)

        // An id change now lands at the width that has ALREADY been applied,
        // so `widthChanged` is false. It is a `.reset`, but not a substitute
        // for the settle reset: every off-band height it carries forward was
        // measured at 600. Cancelling the pending settle here would strand
        // them there permanently.
        let reshuffled = [wrappingSpec("head")] + rows + [wrappingSpec("tail")]
        #expect(
            ACPTranscriptScrollerReconciler.diff(
                oldIds: rows.map(\.id), newIds: reshuffled.map(\.id)
            ) == .reset
        )
        reconciler.apply(specs: reshuffled, contentWidth: 300, followsTail: false)
        #expect(tiling.row(withId: "r199")!.height == offBandHeightWide)

        let graceNanoseconds = UInt64(
            (ACPTranscriptScrollerReconciler.widthChangeSettleInterval + 0.4) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: graceNanoseconds)

        // The settle reset still fires and corrects the off-band rows.
        #expect(tiling.row(withId: "r199")!.height > offBandHeightWide)
    }

    // MARK: mount-time fallback re-measure (final-review IMPORTANT 3)

    @Test("a fallback re-measure of an already-mounted row schedules another layout pass")
    func fallbackRemeasureSchedulesAnotherPass() {
        // The fallback re-measure in `performLayoutPass` has two triggers.
        // A row mounting for the first time is rescued by accident — AppKit
        // fires `invalidateIntrinsicContentSize` synchronously from
        // `addSubview`, which routes into `remeasureRow` and coalesces a
        // relayout. An ALREADY-mounted row re-pinned to a new width has no
        // such rescue: no `addSubview`, and re-assigning `rootView` inside
        // `measuredHeight` does not invalidate. That is the live
        // resize-drag path, and it is what this test drives.
        let (reconciler, scroller, tiling) = makeStack()
        let specs = (0..<60).map { wrappingSpec("r\($0)") }
        reconciler.apply(specs: specs, contentWidth: 300, followsTail: false)
        scroller.setScrollY(0)
        reconciler.layoutMountedRows()
        let narrowHeight = tiling.row(withId: "r0")!.height
        let mountedWhenNarrow = reconciler.mountedRowIdsForTesting.count

        // Widening makes every row shorter, so many more of them fit inside
        // the mount band — but the band was computed from the pre-measure
        // geometry, so without coalescing another pass the extra rows are
        // never mounted and the bottom of the viewport is left empty.
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)

        #expect(tiling.row(withId: "r0")!.height < narrowHeight)
        let band = tiling.mountBand(
            viewportMinY: scroller.scrollY, viewportHeight: scroller.viewportHeight,
            overscan: ACPTranscriptScrollerReconciler.overscan
        )
        #expect(band.count > mountedWhenNarrow)
        #expect(reconciler.mountedRowIdsForTesting == Set(band.map { tiling.rowId(at: $0) }))
    }

    // MARK: head step at the very top (final-review IMPORTANT 5)

    @Test("a head step taken at the very top of the document still keeps the reading position still")
    func headStepAtTopOfDocumentCompensates() {
        let (reconciler, scroller, tiling) = makeStack()
        func specsWithFixedEnds(messageIds: [String]) -> [ACPTranscriptRowSpec] {
            [spec("__top_pagination__", height: 14)]
                + messageIds.map { spec($0) }
                + [spec("__composer_spacer__", height: 220)]
        }
        reconciler.apply(
            specs: specsWithFixedEnds(messageIds: (30..<90).map { "m\($0)" }),
            contentWidth: 600, followsTail: false
        )
        // The top-of-history bounce: the head pagination spinner occupies
        // index 0, so the first message starts at topPadding(24) +
        // spinner(14) + spacing(18) == 56. Parked above that, the plain
        // `insertionY <= viewportMinY` rule declines to compensate and the
        // whole inserted block shoves the reading position down.
        #expect(tiling.row(withId: "m30")!.minY == 56)
        scroller.setScrollY(10)
        let before = screenOffset(of: "m30", tiling: tiling, scroller: scroller)

        reconciler.apply(
            specs: specsWithFixedEnds(messageIds: (10..<90).map { "m\($0)" }),
            contentWidth: 600, followsTail: false
        )

        #expect(abs(screenOffset(of: "m30", tiling: tiling, scroller: scroller) - before) < 1)
    }

    @Test("an append below the reading position never compensates")
    func appendBelowReadingPositionDoesNotCompensate() {
        // Guard against the head-step fix over-reaching: an insertion with
        // real message rows above it must still leave the offset alone.
        let (reconciler, scroller, _) = makeStack()
        func specsWithFixedEnds(messageIds: [String]) -> [ACPTranscriptRowSpec] {
            [spec("__top_pagination__", height: 14)]
                + messageIds.map { spec($0) }
                + [spec("__composer_spacer__", height: 220)]
        }
        reconciler.apply(
            specs: specsWithFixedEnds(messageIds: (0..<60).map { "m\($0)" }),
            contentWidth: 600, followsTail: false
        )
        scroller.setScrollY(10)
        reconciler.apply(
            specs: specsWithFixedEnds(messageIds: (0..<62).map { "m\($0)" }),
            contentWidth: 600, followsTail: false
        )
        #expect(abs(scroller.scrollY - 10) < 0.5)
    }

    @Test("a pure width change with identical ids coalesces: bounded interim work, full correction after settling")
    func widthChangeCoalescesThenSettles() async throws {
        let (reconciler, scroller, tiling) = makeStack()
        // Enough rows that the mount band is a small fraction of the total,
        // so an eager "remeasure everything" reset is distinguishable from
        // the bounded interim work the coalesced path is allowed to do.
        let wideSpecs = (0..<200).map { wrappingSpec("r\($0)") }
        reconciler.apply(specs: wideSpecs, contentWidth: 600, followsTail: false)
        scroller.setScrollY(0)
        let onBandHeightWide = tiling.row(withId: "r0")!.height
        let offBandHeightWide = tiling.row(withId: "r199")!.height

        // Three rapid ticks of a narrowing drag, same ids/tokens throughout.
        reconciler.apply(specs: wideSpecs, contentWidth: 400, followsTail: false)
        reconciler.apply(specs: wideSpecs, contentWidth: 300, followsTail: false)
        reconciler.apply(specs: wideSpecs, contentWidth: 150, followsTail: false)

        // Interim: the on-screen row is corrected immediately (lazily, as
        // it's placed), but the off-screen row must NOT have been eagerly
        // remeasured yet — that's the expensive whole-document reset this
        // coalescing exists to defer.
        #expect(tiling.row(withId: "r0")!.height > onBandHeightWide)
        #expect(tiling.row(withId: "r199")!.height == offBandHeightWide)

        // Let the debounce settle well past the interval. Generous grace
        // (interval + 400ms) matches this codebase's established margin for
        // DispatchWorkItem-based debounce tests (see DebounceTimerTests),
        // which found tighter margins flaky under CI scheduling load.
        let graceNanoseconds = UInt64((ACPTranscriptScrollerReconciler.widthChangeSettleInterval + 0.4) * 1_000_000_000)
        try await Task.sleep(nanoseconds: graceNanoseconds)

        // After settling, every row — including the off-screen one — has
        // been correctly re-measured at the final (narrowest) width.
        #expect(tiling.row(withId: "r199")!.height > offBandHeightWide)
        #expect(tiling.rowCount == 200)
        #expect(scroller.contentHeight == tiling.documentHeight)
    }
}

@MainActor
@Suite("ACPTranscriptScrollerReconciler window layout")
struct ACPTranscriptScrollerReconcilerWindowLayoutTests {
    /// `ACPTranscriptRowHostingView` sets
    /// `translatesAutoresizingMaskIntoConstraints = false` (NSHostingView
    /// boilerplate) while the reconciler places every row by assigning
    /// `frame` directly. Those two are normally mutually exclusive: a view
    /// opted into Auto Layout with no constraints describing it is the
    /// classic "everything collapses to the origin" failure.
    ///
    /// This test pins down what actually happens, inside a real key window
    /// with a real layout pass — the configuration the app runs in — so the
    /// setting is known-correct rather than known-lucky.

    @Test("rows placed by frame keep their frames through a real window layout pass")
    func framePlacedRowsSurviveWindowLayout() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = scroller
        let tiling = ACPTranscriptTilingController()
        let pool = ACPTranscriptRowHostingPool()
        let reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
        scroller.layoutSubtreeIfNeeded()

        let specs = (0..<8).map { index in
            ACPTranscriptRowSpec(
                id: "r\(index)",
                equalityToken: ACPRowEqualityToken(0),
                build: { AnyView(Color.gray.frame(height: 100)) }
            )
        }
        reconciler.apply(specs: specs, contentWidth: 600, followsTail: false)

        window.layoutIfNeeded()
        scroller.layoutSubtreeIfNeeded()
        scroller.flippedDocumentView.displayIfNeeded()

        let placed = scroller.flippedDocumentView.subviews
        #expect(placed.count == reconciler.mountedRowIdsForTesting.count)
        #expect(placed.count == 8)
        for index in 0..<8 {
            let layout = tiling.rowLayout(at: index)
            let view = placed.first { $0 === pool.mountedView(id: layout.id) }
            #expect(view != nil)
            #expect(view?.frame.minY == layout.minY)
            #expect(view?.frame.height == layout.height)
            #expect(view?.frame.width == 600)
        }
    }
}
