import Testing
import Foundation
@testable import Alas

struct MergeRegionVisualLayoutTests {
    private static func block(local: String, base: String? = nil, remote: String) -> ConflictBlock {
        ConflictBlock(
            local: local,
            base: base,
            remote: remote,
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 1 ... 5
        )
    }

    @Test func sidePanesShowTheirVersionWithoutPaddingRows() throws {
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(Self.block(local: "x\ny\n", remote: "z\n")),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        #expect(layout.local.map(\.content) == ["a", "x", "y", "b"])
        #expect(layout.remote.map(\.content) == ["a", "z", "b"])
        #expect(layout.result.map(\.content) == ["a", "x", "y", "z", "b"])
        #expect(layout.local.map(\.sourceLineNumber) == [1, 2, 3, 4])
        #expect(layout.remote.map(\.sourceLineNumber) == [1, 2, 3])
        #expect(layout.resultOrigins == [.local(0), .local(1), .local(2), .remote(1), .local(3)])

        let r = try #require(layout.conflictRanges.first)
        #expect(r.localRows == 1 ..< 3)
        #expect(r.remoteRows == 1 ..< 2)
        #expect(r.resultRows == 1 ..< 4)
        #expect(r.resultLocalRows == 1 ..< 3)
        #expect(r.resultRemoteRows == 3 ..< 4)
        #expect(layout.chunks.map(\.result) == [0 ..< 1, 1 ..< 4, 4 ..< 5])
        #expect(layout.chunks.map(\.remote) == [0 ..< 1, 1 ..< 2, 2 ..< 3])
    }

    @Test func showBaseStacksBaseRowsBetweenTheSidesInResult() throws {
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(Self.block(local: "L\n", base: "B1\nB2\n", remote: "R\n")),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions, showBase: true)
        #expect(layout.result.map(\.content) == ["a", "L", "B1", "B2", "R", "b"])
        #expect(layout.base.map(\.content) == ["a", "B1", "B2", "b"])
        #expect(layout.resultOrigins[2 ... 3] == [.base(1), .base(2)])
        let r = try #require(layout.conflictRanges.first)
        #expect(r.baseRows == 2 ..< 4)
        #expect(r.resultRemoteRows == 4 ..< 5)

        let hidden = MergeRegionVisualLayout.compute(regions: regions, showBase: false)
        #expect(hidden.result.map(\.content) == ["a", "L", "R", "b"])
        #expect(hidden.conflictRanges.first?.baseRows.isEmpty == true)
    }

    @Test func emptyLocalHunkProducesAnEmptyRangeAtTheInsertionPoint() throws {
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(Self.block(local: "", remote: "added\n")),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        let r = try #require(layout.conflictRanges.first)
        #expect(r.localRows == 1 ..< 1)
        #expect(r.resultRows == 1 ..< 2)
        #expect(r.remoteRows == 1 ..< 2)
    }

    /// Text chunks map 1:1; a conflict maps proportionally, so panes meet
    /// exactly at hunk boundaries and move continuously inside hunks.
    @Test(arguments: [
        (0.5, MergeRegionVisualLayout.Pane.local, MergeRegionVisualLayout.Pane.result, 0.5),
        (1.0, .local, .result, 1.0),
        (2.0, .local, .result, 2.5),   // halfway through LOCAL's 2 rows → halfway through RESULT's 3
        (3.0, .local, .result, 4.0),   // end of the hunk lines up
        (3.5, .local, .remote, 2.5),   // shared text after the conflict
        (2.5, .result, .remote, 1.5),
        (9.0, .local, .remote, 8.0),   // past the end keeps the trailing offset
    ])
    func mapRowInterpolatesWithinChunks(row: Double, from: MergeRegionVisualLayout.Pane, to: MergeRegionVisualLayout.Pane, expected: Double) {
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(Self.block(local: "x\ny\n", remote: "z\n")),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        #expect(abs(layout.mapRow(row, from: from, to: to) - expected) < 0.0001)
    }
}
