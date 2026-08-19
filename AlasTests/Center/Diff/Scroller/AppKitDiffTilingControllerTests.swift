import CoreGraphics
import Testing
@testable import Alas

@MainActor
@Suite("AppKit diff tiling")
struct AppKitDiffTilingControllerTests {
    private func controller(
        rowSpacing: CGFloat = 0,
        topPadding: CGFloat = 0,
        bottomPadding: CGFloat = 0
    ) -> AppKitDiffTilingController {
        AppKitDiffTilingController(
            metrics: .init(
                rowSpacing: rowSpacing,
                topPadding: topPadding,
                bottomPadding: bottomPadding
            )
        )
    }

    @Test("mount band stays bounded and active owner follows the viewport")
    func mountBandAndOwner() {
        let tiling = controller()
        tiling.replaceAll(rows: (0..<100).map {
            .init(id: "row-\($0)", ownerID: "file-\($0 / 10)", height: 20)
        })

        #expect(tiling.mountBand(viewportMinY: 800, viewportHeight: 100, overscan: 100) == 35..<50)
        #expect(tiling.activeOwnerID(viewportMinY: 800, viewportHeight: 100) == "file-4")
    }

    @Test("height growth above the viewport returns exact compensation")
    func heightCompensation() {
        let tiling = controller()
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])

        #expect(tiling.updateHeight(id: "a", to: 140, viewportMinY: 100) == 40)
        #expect(tiling.row(withID: "b")?.minY == 140)
    }

    @Test("anchor records intra-row position and resolves after reorder")
    func anchorRestoration() {
        let tiling = controller()
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])

        let anchor = tiling.anchor(viewportMinY: 130)
        #expect(anchor == .init(rowID: "b", intraRowOffset: 30))
        tiling.replaceAll(rows: [
            .init(id: "x", ownerID: nil, height: 50),
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])
        #expect(tiling.viewportMinY(for: anchor) == 180)
    }

    @Test("empty and past-end viewports have no rows or owners")
    func emptyAndPastEndViewports() {
        let tiling = controller()
        #expect(tiling.mountBand(viewportMinY: 0, viewportHeight: 100, overscan: 20).isEmpty)
        #expect(tiling.anchor(viewportMinY: 0) == nil)
        #expect(tiling.activeOwnerID(viewportMinY: 0, viewportHeight: 100) == nil)

        tiling.replaceAll(rows: [.init(id: "a", ownerID: "file-a", height: 100)])
        #expect(tiling.mountBand(viewportMinY: 100, viewportHeight: 100, overscan: 0) == 1..<1)
        #expect(tiling.anchor(viewportMinY: 100) == nil)
        #expect(tiling.activeOwnerID(viewportMinY: 100, viewportHeight: 100) == nil)
    }

    @Test("top padding and row spacing do not intersect a viewport")
    func gapsDoNotIntersectViewport() {
        let tiling = controller(rowSpacing: 20, topPadding: 10)
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: "file-a", height: 100),
            .init(id: "b", ownerID: "file-b", height: 100),
        ])

        #expect(tiling.mountBand(viewportMinY: 0, viewportHeight: 10, overscan: 0).isEmpty)
        #expect(tiling.activeOwnerID(viewportMinY: 0, viewportHeight: 10) == nil)
        #expect(tiling.anchor(viewportMinY: 0) == nil)

        #expect(tiling.mountBand(viewportMinY: 110, viewportHeight: 20, overscan: 0).isEmpty)
        #expect(tiling.activeOwnerID(viewportMinY: 110, viewportHeight: 20) == nil)
        #expect(tiling.anchor(viewportMinY: 110) == nil)
    }

    @Test("center target offset clamps to the top and document bottom")
    func centerOffsetClamping() {
        let tiling = controller()
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
            .init(id: "c", ownerID: nil, height: 100),
        ])

        #expect(tiling.targetOffset(id: "a", alignment: .center, viewportHeight: 200) == 0)
        #expect(tiling.targetOffset(id: "c", alignment: .center, viewportHeight: 200) == 100)
    }

    @Test("padding participates in row placement and document height")
    func paddingLayout() {
        let tiling = controller(rowSpacing: 10, topPadding: 20, bottomPadding: 30)
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 50),
        ])

        #expect(tiling.row(withID: "a")?.minY == 20)
        #expect(tiling.row(withID: "b")?.minY == 130)
        #expect(tiling.documentHeight == 210)
        #expect(tiling.targetOffset(id: "b", alignment: .top, viewportHeight: 100) == 110)
    }

    @Test("height change within the viewport does not compensate")
    func visibleHeightChangeDoesNotCompensate() {
        let tiling = controller()
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 100),
            .init(id: "b", ownerID: nil, height: 100),
        ])

        #expect(tiling.updateHeight(id: "a", to: 140, viewportMinY: 50) == 0)
    }

    @Test("anchor restoration clamps invalid intra-row offsets")
    func anchorRestorationClampsOffsets() {
        let tiling = controller(topPadding: 10, bottomPadding: 20)
        tiling.replaceAll(rows: [.init(id: "a", ownerID: nil, height: 100)])

        #expect(tiling.viewportMinY(for: .init(rowID: "a", intraRowOffset: -20)) == 10)
        #expect(tiling.viewportMinY(for: .init(rowID: "a", intraRowOffset: 200)) == 110)
    }

    @Test("row equality tokens compare equal values of the same type")
    func equalityTokens() {
        let number = AppKitDiffRowEqualityToken(1)
        #expect(number.isEqual(to: AppKitDiffRowEqualityToken(1)))
        #expect(!number.isEqual(to: AppKitDiffRowEqualityToken("1")))
    }

    @Test("duplicate IDs map to the last row index")
    func duplicateIDsUseLastIndex() {
        let indexByID = AppKitDiffTilingController.lastIndexByID(for: ["a", "b", "a"])

        #expect(indexByID == ["a": 2, "b": 1])
    }

    @Test("sticky header follows the viewport and yields to the next header")
    func stickyHeaderLayout() {
        let tiling = controller()
        tiling.replaceAll(rows: [
            .init(id: "working", ownerID: nil, height: 30),
            .init(id: "file", ownerID: nil, height: 100),
            .init(id: "commits", ownerID: nil, height: 30),
            .init(id: "commit", ownerID: nil, height: 100),
        ])

        #expect(tiling.stickyRowLayout(ids: ["working", "commits"], viewportMinY: 50) == .init(id: "working", minY: 50))
        #expect(tiling.stickyRowLayout(ids: ["working", "commits"], viewportMinY: 120) == .init(id: "working", minY: 100))
        #expect(tiling.stickyRowLayout(ids: ["working", "commits"], viewportMinY: 150) == .init(id: "commits", minY: 150))
    }
}
