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

    @Test("row equality tokens compare equal values of the same type")
    func equalityTokens() {
        let number = AppKitDiffRowEqualityToken(1)
        #expect(number.isEqual(to: AppKitDiffRowEqualityToken(1)))
        #expect(!number.isEqual(to: AppKitDiffRowEqualityToken("1")))
    }

    // Duplicate IDs deliberately trigger a debug assertion. The controller
    // still assigns the last entry deterministically in non-asserting builds.
    @Test("duplicate IDs use the last layout outside debug assertions", .disabled("Debug assertions intentionally trap on duplicate IDs"))
    func duplicateIDsUseLastLayout() {
        let tiling = controller()
        tiling.replaceAll(rows: [
            .init(id: "a", ownerID: nil, height: 10),
            .init(id: "a", ownerID: nil, height: 20),
        ])
        #expect(tiling.index(ofID: "a") == 1)
    }
}
