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
}
