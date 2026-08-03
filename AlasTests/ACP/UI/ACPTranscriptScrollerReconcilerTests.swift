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
}
