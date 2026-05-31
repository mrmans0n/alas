import Testing
import Foundation
@testable import Alas

@MainActor
struct MergeScrollCoordinatorTests {
    @Test func defaultsToRowZero() {
        let coord = MergeScrollCoordinator()
        #expect(coord.logicalRow == 0)
        #expect(coord.scrollY == 0)
    }

    @Test func paneYToLogicalRowRoundTrip() {
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 16
        coord.setLogicalRow(7)
        #expect(coord.paneY() == 112)
        coord.applyPaneY(48, source: .local)
        #expect(coord.logicalRow == 3)
        #expect(coord.scrollY == 48)
    }

    @Test func pixelScrollOffsetIsPreserved() {
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 16
        var resultObserved: [CGFloat] = []
        coord.onSyncResult = { resultObserved.append($0) }

        coord.applyPaneY(48.5, source: .local)

        #expect(coord.logicalRow == 3)
        #expect(coord.scrollY == 48.5)
        #expect(resultObserved == [48.5])
    }

    @Test func reentryGuardPreventsLoops() {
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 16
        var localObserved: [CGFloat] = []
        var resultObserved: [CGFloat] = []
        var remoteObserved: [CGFloat] = []
        coord.onSyncLocal = { localObserved.append($0) }
        coord.onSyncResult = { resultObserved.append($0) }
        coord.onSyncRemote = { remoteObserved.append($0) }
        // Source = .result → should broadcast to .local and .remote
        coord.applyPaneY(32, source: .result)
        #expect(coord.logicalRow == 2)
        #expect(localObserved == [32])
        #expect(remoteObserved == [32])
        #expect(resultObserved.isEmpty) // never bounced back to source
    }

    @Test func repeatedSamePixelOffsetDoesNotRebroadcast() {
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 16
        var resultObserved: [CGFloat] = []
        coord.onSyncResult = { resultObserved.append($0) }

        coord.applyPaneY(48.5, source: .local)
        coord.applyPaneY(48.5, source: .local)

        #expect(resultObserved == [48.5])
    }
}
