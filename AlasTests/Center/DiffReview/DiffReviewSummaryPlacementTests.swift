import Foundation
import Testing
@testable import Alas

struct DiffReviewSummaryPlacementTests {
    private let railWidth = DiffReviewRailMetrics.expandedWidth
    private let collapsedRailWidth = DiffReviewRailMetrics.collapsedWidth
    private let minimumCenter = DiffReviewSummaryPlacement.minimumCenterWidthForRail

    @Test func wideSurfaceKeepsTheRail() {
        let width = railWidth + railWidth + minimumCenter + 200
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: width, fileRailCollapsed: false) == .rail)
    }

    @Test func exactlyMinimumCenterKeepsTheRail() {
        let width = railWidth + railWidth + minimumCenter
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: width, fileRailCollapsed: false) == .rail)
    }

    @Test func onePointUnderMinimumCenterMovesTheSummaryInline() {
        let width = railWidth + railWidth + minimumCenter - 1
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: width, fileRailCollapsed: false) == .inline)
    }

    @Test func collapsedFileRailFreesRoomForTheSummaryRail() {
        let width = collapsedRailWidth + railWidth + minimumCenter
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: width, fileRailCollapsed: false) == .inline)
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: width, fileRailCollapsed: true) == .rail)
    }

    @Test func collapsedSummaryRailFreesRoomForItself() {
        // Regression for a case where the resolver ignored the summary
        // rail's own collapsed width: with the file rail expanded and the
        // summary rail already collapsed, 900pt leaves 900 - 260 - 44 = 596pt
        // for the diff, comfortably above the minimum, so the compact rail
        // should stay rather than being replaced by the full inline summary.
        let width: CGFloat = 900
        #expect(
            DiffReviewSummaryPlacement.resolve(
                availableWidth: width,
                fileRailCollapsed: false,
                summaryRailCollapsed: false
            ) == .inline
        )
        #expect(
            DiffReviewSummaryPlacement.resolve(
                availableWidth: width,
                fileRailCollapsed: false,
                summaryRailCollapsed: true
            ) == .rail
        )
    }

    @Test func unknownWidthDefaultsToTheRail() {
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: 0, fileRailCollapsed: false) == .rail)
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: -10, fileRailCollapsed: false) == .rail)
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: .nan, fileRailCollapsed: false) == .rail)
        #expect(DiffReviewSummaryPlacement.resolve(availableWidth: .infinity, fileRailCollapsed: false) == .rail)
    }
}
