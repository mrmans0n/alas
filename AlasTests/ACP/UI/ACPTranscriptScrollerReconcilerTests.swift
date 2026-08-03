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

    private func spec(_ id: String, token: Int = 0, height: CGFloat = 100) -> ACPTranscriptRowSpec {
        ACPTranscriptRowSpec(
            id: id,
            equalityToken: ACPRowEqualityToken(token),
            build: { AnyView(Color.clear.frame(height: height)) }
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
