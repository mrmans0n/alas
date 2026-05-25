import Testing
import Foundation
@testable import Alas

@MainActor
struct MergeScrollCoordinatorTests {
    @Test func defaultsToRowZero() {
        let coord = MergeScrollCoordinator()
        #expect(coord.logicalRow == 0)
    }

    @Test func paneYToLogicalRowRoundTrip() {
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 16
        coord.setLogicalRow(7)
        #expect(coord.paneY() == 112)
        coord.applyPaneY(48, source: .local)
        #expect(coord.logicalRow == 3)
    }

    @Test func reentryGuardPreventsLoops() {
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 16
        var observed: [Int] = []
        coord.onSync = { _, row in observed.append(row) }
        coord.applyPaneY(32, source: .result)
        #expect(coord.logicalRow == 2)
        #expect(observed.count == 2)
        #expect(observed == [2, 2])
    }
}
