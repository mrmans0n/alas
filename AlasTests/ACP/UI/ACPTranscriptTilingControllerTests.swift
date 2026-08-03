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
