import CoreGraphics
import Testing
@testable import Alas

@MainActor
@Suite("ACPTranscriptTilingController core")
struct ACPTranscriptTilingControllerTests {
    private func controller() -> ACPTranscriptTilingController {
        ACPTranscriptTilingController(
            metrics: .init(rowSpacing: 10, topPadding: 20)
        )
    }

    @Test("replaceAll lays rows top-down with spacing and top padding")
    func layoutBasics() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80)])
        #expect(c.rowCount == 3)
        #expect(c.row(withId: "a")?.minY == 20)
        #expect(c.row(withId: "b")?.minY == 130)   // 20 + 100 + 10
        #expect(c.row(withId: "c")?.minY == 190)   // 130 + 50 + 10
        #expect(c.documentHeight == 270)           // 190 + 80
    }

    @Test("firstNonSyntheticRowId walks past a synthetic row at the viewport top")
    func firstNonSyntheticSkipsLeadingSynthetic() {
        // The reported case: scrolled to the head of a paginated transcript,
        // where the pagination spinner is the topmost row. Returning nil
        // there means no anchor is remembered at all, and restoration later
        // reads "no anchor" as "go to the bottom".
        let c = controller()
        c.replaceAll(rows: [("__top_pagination__", 40), ("m0", 100), ("m1", 100)])

        #expect(c.topVisibleRowId(viewportMinY: 20) == "__top_pagination__")
        #expect(
            c.firstNonSyntheticRowId(atOrBelow: 20, syntheticIdPrefix: "__") == "m0"
        )
    }

    @Test("firstNonSyntheticRowId returns the row itself when it is not synthetic")
    func firstNonSyntheticKeepsRealRow() {
        let c = controller()
        c.replaceAll(rows: [("__top_pagination__", 40), ("m0", 100), ("m1", 100)])

        // Deep enough to be inside "m1", which is a real row: no scanning.
        #expect(
            c.firstNonSyntheticRowId(atOrBelow: 200, syntheticIdPrefix: "__") == "m1"
        )
    }

    @Test("firstNonSyntheticRowId returns nil when only synthetic rows remain below")
    func firstNonSyntheticNilInSyntheticTail() {
        // Viewport top inside the synthetic tail (queued prompts, composer
        // spacer): there is no message below to name, so there is genuinely
        // nothing to remember.
        let c = controller()
        c.replaceAll(rows: [("m0", 100), ("__queued__", 60), ("__composer_spacer__", 220)])

        #expect(
            c.firstNonSyntheticRowId(atOrBelow: 200, syntheticIdPrefix: "__") == nil
        )
    }

    @Test("firstNonSyntheticRowId returns nil past the end of the document")
    func firstNonSyntheticNilPastEnd() {
        let c = controller()
        c.replaceAll(rows: [("m0", 100)])

        #expect(
            c.firstNonSyntheticRowId(atOrBelow: 10_000, syntheticIdPrefix: "__") == nil
        )
    }

    @Test("nearestNonSyntheticRowId falls back upward when only synthetic rows remain below")
    func nearestNonSyntheticFallsBackUpward() {
        // Viewport stopped inside the synthetic tail. The forward scan has
        // nothing to find, and recording no anchor at all is read downstream
        // as "go to the bottom" — so the last real message above is the
        // closest position the persisted anchor format can express.
        let c = controller()
        c.replaceAll(rows: [("m0", 100), ("m1", 100), ("__queued__", 60), ("__composer_spacer__", 220)])

        #expect(
            c.firstNonSyntheticRowId(atOrBelow: 300, syntheticIdPrefix: "__") == nil
        )
        #expect(
            c.nearestNonSyntheticRowId(to: 300, syntheticIdPrefix: "__") == "m1"
        )
    }

    @Test("nearestNonSyntheticRowId still prefers the row below when there is one")
    func nearestNonSyntheticPrefersBelow() {
        let c = controller()
        c.replaceAll(rows: [("m0", 100), ("__queued__", 60), ("m1", 100)])

        // Sitting on the queued bubble: "m1" is below and "m0" above, and
        // the downward answer must win so the anchor never drifts backward
        // while a real row is still in view.
        #expect(
            c.nearestNonSyntheticRowId(to: 130, syntheticIdPrefix: "__") == "m1"
        )
    }

    @Test("nearestNonSyntheticRowId past the end of the document returns the last message")
    func nearestNonSyntheticPastEnd() {
        let c = controller()
        c.replaceAll(rows: [("m0", 100), ("__composer_spacer__", 220)])

        #expect(
            c.nearestNonSyntheticRowId(to: 10_000, syntheticIdPrefix: "__") == "m0"
        )
    }

    @Test("nearestNonSyntheticRowId returns nil when the document has no message rows")
    func nearestNonSyntheticAllSynthetic() {
        let c = controller()
        c.replaceAll(rows: [("__top_pagination__", 40), ("__composer_spacer__", 220)])

        #expect(
            c.nearestNonSyntheticRowId(to: 0, syntheticIdPrefix: "__") == nil
        )
    }

    @Test("empty controller has zero document height")
    func emptyHeight() {
        let c = controller()
        #expect(c.rowCount == 0)
        #expect(c.documentHeight == 0)
    }

    @Test("prepend returns the exact delta and shifts existing rows by it")
    func prependDelta() {
        let c = controller()
        c.replaceAll(rows: [("c", 80), ("d", 40)])
        let cMinYBefore = c.row(withId: "c")!.minY
        let delta = c.prepend(rows: [("a", 100), ("b", 50)])
        // heights + one spacing per row
        let expectedDelta: CGFloat = 100 + 10 + 50 + 10
        #expect(delta == expectedDelta)
        #expect(c.row(withId: "a")?.minY == 20)
        #expect(c.row(withId: "c")?.minY == cMinYBefore + delta)
        let expectedDocumentHeight: CGFloat = 20 + 100 + 10 + 50 + 10 + 80 + 10 + 40
        #expect(c.documentHeight == expectedDocumentHeight)
    }

    @Test("append extends the document without moving existing rows")
    func appendKeepsExisting() {
        let c = controller()
        c.replaceAll(rows: [("a", 100)])
        let aBefore = c.row(withId: "a")!.minY
        c.append(rows: [("b", 60)])
        #expect(c.row(withId: "a")?.minY == aBefore)
        let expectedBMinY: CGFloat = 20 + 100 + 10
        #expect(c.row(withId: "b")?.minY == expectedBMinY)
        #expect(c.documentHeight == 190)
    }

    @Test("removeSuffix truncates rows and document height")
    func removeSuffix() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80)])
        c.removeSuffix(from: 1)
        #expect(c.rowCount == 1)
        #expect(c.row(withId: "b") == nil)
        #expect(c.documentHeight == 120)           // 20 + 100
    }

    @Test("rowId and rowLayout are index-addressable")
    func indexAddressing() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50)])
        #expect(c.rowId(at: 1) == "b")
        #expect(c.rowLayout(at: 0).height == 100)
    }

    // Note: rebuildIndex()'s duplicate-id tolerance (last occurrence wins)
    // cannot be covered by an in-process test here. It is guarded by
    // `assertionFailure`, which traps as a genuine Fatal error under the
    // Debug configuration this test target always runs in — verified
    // empirically: a duplicate-id row crashed the entire xctest process
    // rather than failing a single test. See the fix report for the
    // reproduction. The test below instead covers the part that IS safely
    // testable: that the id index only ever reflects current, non-duplicate
    // rows after a mix of mutations.
    @Test("index reflects only current rows after truncation and regrowth")
    func indexRebuildsCleanlyAfterMutations() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80)])
        c.removeSuffix(from: 1)
        c.append(rows: [("d", 30)])
        #expect(c.row(withId: "b") == nil)
        #expect(c.row(withId: "c") == nil)
        #expect(c.rowId(at: 1) == "d")
        #expect(c.row(withId: "d")?.minY == c.rowLayout(at: 1).minY)
    }
}

@MainActor
@Suite("ACPTranscriptTilingController generalized insert/remove")
struct ACPTranscriptTilingInsertRemoveTests {
    private func controller() -> ACPTranscriptTilingController {
        ACPTranscriptTilingController(metrics: .init(rowSpacing: 10, topPadding: 20))
    }

    @Test("insert at a mid-list index shifts only rows from that index onward")
    func midListInsertion() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("d", 40), ("e", 30)])
        // a=20, b=130, d=190, e=240; documentHeight = 270
        let aMinYBefore = c.row(withId: "a")!.minY
        let bMinYBefore = c.row(withId: "b")!.minY
        _ = c.insert(rows: [("c", 80)], at: 2, viewportMinY: 10_000)
        #expect(c.rowCount == 5)
        #expect(c.row(withId: "a")?.minY == aMinYBefore)
        #expect(c.row(withId: "b")?.minY == bMinYBefore)
        let expectedCMinY: CGFloat = 190
        #expect(c.row(withId: "c")?.minY == expectedCMinY)
        let expectedDMinY: CGFloat = 280
        #expect(c.row(withId: "d")?.minY == expectedDMinY)
        let expectedDocumentHeight: CGFloat = 360
        #expect(c.documentHeight == expectedDocumentHeight)
    }

    @Test("insert compensates when the insertion point is at or above the viewport top")
    func insertCompensatesAboveViewport() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50)])
        // a=20..120, b=130..180. Insertion point (b's pre-mutation minY,
        // 130) exactly meets viewportMinY: half-open convention treats
        // this as "at or above" (same boundary rule as `updateHeight`).
        let compensation = c.insert(rows: [("z", 40)], at: 1, viewportMinY: 130)
        let expectedDelta: CGFloat = 40 + 10
        #expect(compensation == expectedDelta)
        let expectedBMinY: CGFloat = 130 + expectedDelta
        #expect(c.row(withId: "b")?.minY == expectedBMinY)
    }

    @Test("insert does not compensate when the insertion point is below the viewport top")
    func insertDoesNotCompensateBelowViewport() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50)])
        // Insertion point (b's pre-mutation minY, 130) is below viewportMinY 0:
        // the viewport is scrolled to the very top, above where the insert lands.
        let compensation = c.insert(rows: [("z", 40)], at: 1, viewportMinY: 0)
        #expect(compensation == 0)
    }

    @Test("insert into an empty controller never compensates even at viewportMinY 0")
    func insertIntoEmptyControllerDoesNotCompensate() {
        let c = controller()
        // insertionY and viewportMinY are both 0 here, which the naive rule
        // would treat as "at or above" — but there was no existing content
        // to protect, so a first-ever populate must never compensate.
        let compensation = c.insert(rows: [("a", 100)], at: 0, viewportMinY: 0)
        #expect(compensation == 0)
        #expect(c.rowCount == 1)
        #expect(c.row(withId: "a")?.minY == 20)
    }

    @Test("remove at a mid-list index shifts only rows after the removed range")
    func midListRemoval() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80), ("d", 40)])
        // a=20, b=130, c=190, d=280; documentHeight=320
        let aMinYBefore = c.row(withId: "a")!.minY
        _ = c.remove(at: 1, count: 1, viewportMinY: 10_000)
        #expect(c.rowCount == 3)
        #expect(c.row(withId: "b") == nil)
        #expect(c.row(withId: "a")?.minY == aMinYBefore)
        let expectedCMinY: CGFloat = 130
        #expect(c.row(withId: "c")?.minY == expectedCMinY)
        let expectedDocumentHeight: CGFloat = 260
        #expect(c.documentHeight == expectedDocumentHeight)
    }

    @Test("remove compensates negatively when the removal point is at or above the viewport top")
    func removeCompensatesAboveViewport() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80)])
        // a=20..120, b=130..180, c=190..270. Removing "a" (removalY 20) is
        // well above a viewport scrolled to 190.
        let compensation = c.remove(at: 0, count: 1, viewportMinY: 190)
        let expectedDelta: CGFloat = -(100 + 10)
        #expect(compensation == expectedDelta)
    }

    @Test("remove does not compensate when the removal point is below the viewport top")
    func removeDoesNotCompensateBelowViewport() {
        let c = controller()
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80)])
        // Removing "b" (removalY 130) while the viewport is at the very top.
        let compensation = c.remove(at: 1, count: 1, viewportMinY: 0)
        #expect(compensation == 0)
    }

    @Test("removing every row leaves an empty controller")
    func removeEverything() {
        let c = controller()
        c.replaceAll(rows: [("a", 100)])
        _ = c.remove(at: 0, count: 1, viewportMinY: 0)
        #expect(c.rowCount == 0)
        #expect(c.documentHeight == 0)
    }
}

@MainActor
@Suite("ACPTranscriptTilingController height updates")
struct ACPTranscriptTilingHeightTests {
    private func controller() -> ACPTranscriptTilingController {
        let c = ACPTranscriptTilingController(metrics: .init(rowSpacing: 10, topPadding: 20))
        c.replaceAll(rows: [("a", 100), ("b", 50), ("c", 80), ("d", 40)])
        // minY: a=20, b=130, c=190, d=280 ; documentHeight=320
        return c
    }

    @Test("growing a row above the viewport returns the growth as compensation")
    func growthAboveViewport() {
        let c = controller()
        let delta = c.updateHeight(id: "a", to: 150, viewportMinY: 190)
        #expect(delta == 50)
        #expect(c.row(withId: "b")?.minY == 180)
        #expect(c.documentHeight == 370)
    }

    @Test("shrinking a row above the viewport returns negative compensation")
    func shrinkAboveViewport() {
        let c = controller()
        let delta = c.updateHeight(id: "a", to: 60, viewportMinY: 190)
        #expect(delta == -40)
        #expect(c.documentHeight == 280)
    }

    @Test("growing a row visible in or below the viewport needs no compensation")
    func growthBelowViewport() {
        let c = controller()
        let delta = c.updateHeight(id: "c", to: 120, viewportMinY: 100)
        #expect(delta == 0)
        #expect(c.row(withId: "d")?.minY == 320)
        #expect(c.documentHeight == 360)
    }

    @Test("unchanged height is a no-op")
    func unchangedNoop() {
        let c = controller()
        let delta = c.updateHeight(id: "b", to: 50, viewportMinY: 0)
        #expect(delta == 0)
        #expect(c.documentHeight == 320)
    }

    @Test("unknown id is a no-op")
    func unknownId() {
        let c = controller()
        #expect(c.updateHeight(id: "zz", to: 99, viewportMinY: 0) == 0)
        #expect(c.documentHeight == 320)
    }

    @Test("a row whose bottom edge exactly meets the viewport top counts as above")
    func exactBoundaryIsAbove() {
        let c = controller()
        // b occupies the half-open range [minY, maxY) = [130, 180). When
        // viewportMinY == 180, the first visible pixel is row b's old maxY:
        // none of b's pixels are actually on screen, so it is entirely above
        // the viewport (not "visible"), and its growth must be compensated.
        let delta = c.updateHeight(id: "b", to: 70, viewportMinY: 180)
        let expectedDelta: CGFloat = 70 - 50
        #expect(delta == expectedDelta)
        #expect(c.documentHeight == 340)
    }
}

@MainActor
@Suite("ACPTranscriptTilingController viewport queries")
struct ACPTranscriptTilingViewportTests {
    private func controller() -> ACPTranscriptTilingController {
        let c = ACPTranscriptTilingController(metrics: .init(rowSpacing: 10, topPadding: 20))
        c.replaceAll(rows: (0..<100).map { ("row-\($0)", 100) })
        // row-i: minY = 20 + i*110, maxY = minY + 100
        return c
    }

    @Test("top visible row is the first row whose bottom is past the viewport top")
    func topVisible() {
        let c = controller()
        #expect(c.topVisibleRowId(viewportMinY: 0) == "row-0")
        #expect(c.topVisibleRowId(viewportMinY: 121) == "row-1")   // row-0.maxY = 120
        #expect(c.topVisibleRowId(viewportMinY: 5000) == "row-45") // first maxY > 5000: 120 + 110*45 = 5070
    }

    @Test("top visible row of an empty controller is nil")
    func topVisibleEmpty() {
        let c = ACPTranscriptTilingController()
        #expect(c.topVisibleRowId(viewportMinY: 0) == nil)
    }

    @Test("mount band covers viewport plus overscan and clamps to bounds")
    func mountBand() {
        let c = controller()
        let band = c.mountBand(viewportMinY: 1000, viewportHeight: 800, overscan: 500)
        // covered y-range: [500, 2300]
        let first = band.lowerBound, last = band.upperBound - 1
        #expect(c.rowLayout(at: first).maxY > 500)
        if first > 0 { #expect(c.rowLayout(at: first - 1).maxY <= 500) }
        #expect(c.rowLayout(at: last).minY < 2300)
        if last < c.rowCount - 1 { #expect(c.rowLayout(at: last + 1).minY >= 2300) }
    }

    @Test("mount band at the very top starts at zero")
    func mountBandTop() {
        let c = controller()
        let band = c.mountBand(viewportMinY: 0, viewportHeight: 800, overscan: 500)
        #expect(band.lowerBound == 0)
    }

    @Test("mount band of an empty controller is empty")
    func mountBandEmpty() {
        let c = ACPTranscriptTilingController()
        #expect(c.mountBand(viewportMinY: 0, viewportHeight: 800, overscan: 500).isEmpty)
    }
}
