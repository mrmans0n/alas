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

    @Test("new ids before the old head are a prepend")
    func prepend() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["c", "d"], newIds: ["a", "b", "c", "d"])
            == .prepended(count: 2)
        )
    }

    @Test("new ids after the old tail are an append")
    func append() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b"], newIds: ["a", "b", "c"])
            == .appended(count: 1)
        )
    }

    @Test("prepend and append together are recognized")
    func both() {
        #expect(
            ACPTranscriptScrollerReconciler.diff(oldIds: ["b"], newIds: ["a", "b", "c"])
            == .prependedAndAppended(prepended: 1, appended: 1)
        )
    }

    @Test("anything else is a reset")
    func reset() {
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b"], newIds: ["a", "c"]) == .reset)
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a", "b"], newIds: ["b"]) == .reset)
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: ["a"], newIds: ["z"]) == .reset)
    }

    @Test("empty transitions")
    func empties() {
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: [], newIds: ["a"]) == .reset)
        #expect(ACPTranscriptScrollerReconciler.diff(oldIds: [], newIds: []) == .unchanged)
    }
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
        // the old (pre-reset) tiling geometry: `.reset` doesn't touch
        // scrollY on its own (followsTail is false here).
        #expect(scroller.scrollY == 300)
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
