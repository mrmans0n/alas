import Testing
import Foundation
@testable import Alas

@MainActor
struct MergeScrollCoordinatorTests {
    /// LOCAL: a x y b (4 rows). RESULT: a x y z b (5 rows). REMOTE: a z b (3 rows).
    private static func coordinator() -> MergeScrollCoordinator {
        let block = ConflictBlock(
            local: "x\ny\n",
            base: nil,
            remote: "z\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 1 ... 5
        )
        let coord = MergeScrollCoordinator()
        coord.rowHeight = 10
        coord.contentTopInset = 0
        coord.viewportHeight = 0
        coord.layout = MergeRegionVisualLayout.compute(regions: [.text("a\n"), .conflict(block), .text("b\n")])
        return coord
    }

    @Test func userScrollMovesOtherPanesToTheCorrespondingRow() {
        let coord = Self.coordinator()
        var result: [CGFloat] = []
        var remote: [CGFloat] = []
        coord.register(.result) { y in
            result.append(y)
            return y
        }
        coord.register(.remote) { y in
            remote.append(y)
            return y
        }

        // Row 2 of LOCAL is halfway through its 2-row hunk.
        coord.applyPaneY(20, source: .local)

        #expect(result == [25])
        #expect(remote == [15])
        #expect(coord.offset(for: .result) == 25)
    }

    @Test func syncEchoesAndClampingDoNotRebroadcast() {
        let coord = Self.coordinator()
        var localCalls = 0
        coord.register(.local) { _ in
            localCalls += 1
            return 0
        }
        coord.register(.result) { y in
            // AppKit posts boundsDidChange synchronously while handling a
            // programmatic scroll, and may clamp the offset.
            let clamped = min(y, 12)
            coord.applyPaneY(clamped, source: .result)
            return clamped
        }

        coord.applyPaneY(30, source: .remote)

        #expect(localCalls == 1)
        #expect(coord.offset(for: .result) == 12)
        #expect(coord.offset(for: .remote) == 30)
    }

    @Test func repeatedOffsetDoesNotRebroadcastButObserversHearEveryScroll() {
        let coord = Self.coordinator()
        var resultCalls = 0
        var observed = 0
        coord.register(.result) { y in
            resultCalls += 1
            return y
        }
        let id = coord.addScrollObserver { observed += 1 }

        coord.applyPaneY(10, source: .local)
        coord.applyPaneY(10, source: .local)
        coord.scroll(.local, toY: 20)
        coord.removeScrollObserver(id)
        coord.applyPaneY(30, source: .local)

        #expect(resultCalls == 3)
        #expect(observed == 2)
    }

    @Test func mappingAnchorsOnTheViewportCenter() {
        let coord = Self.coordinator()
        coord.viewportHeight = 20
        // LOCAL at y = 10 has row 2 (mid-hunk) at its center, which maps to
        // RESULT row 2.5; RESULT must put that row at its own center.
        #expect(coord.mappedOffset(10, from: .local, to: .result) == 15)
        #expect(coord.mappedOffset(0, from: .local, to: .result) == 0)
    }
}
