import Testing
import Foundation
@testable import Alas

struct MergeRegionVisualLayoutTests {
    @Test func noConflictsKeepsRowsAlignedOneToOne() {
        let regions: [ConflictRegion] = [.text("a\nb\nc\n")]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        #expect(layout.local.count == 3)
        #expect(layout.result.count == 3)
        #expect(layout.remote.count == 3)
        #expect(layout.local.allSatisfy { !$0.isPadding })
        #expect(layout.conflictRanges.isEmpty)
    }

    @Test func singleConflictPadsLocalBelowAndRemoteAbove() {
        let block = ConflictBlock(
            local: "x\ny\n",
            base: nil,
            remote: "z\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 1 ... 5
        )
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(block),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        #expect(layout.local.count == 5)
        #expect(layout.result.count == 5)
        #expect(layout.remote.count == 5)
        #expect(layout.local[0].isPadding == false)
        #expect(layout.local[1].isPadding == false)
        #expect(layout.local[2].isPadding == false)
        #expect(layout.local[3].isPadding == true)
        #expect(layout.local[4].isPadding == false)
        #expect(layout.remote[0].isPadding == false)
        #expect(layout.remote[1].isPadding == true)
        #expect(layout.remote[2].isPadding == true)
        #expect(layout.remote[3].isPadding == false)
        #expect(layout.remote[4].isPadding == false)
    }

    @Test func conflictRangesPointAtTheCorrectVisualRows() {
        let block = ConflictBlock(
            local: "x\ny\n",
            base: nil,
            remote: "z\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 1 ... 5
        )
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(block),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        #expect(layout.conflictRanges.count == 1)
        let r = layout.conflictRanges[0]
        #expect(r.resultRows == 1 ... 3)
        #expect(r.localRows == 1 ... 2)
        #expect(r.remoteRows == 3 ... 3)
    }

    @Test func sourceLineNumbersTrackRealContentOnly() {
        let block = ConflictBlock(
            local: "x\n",
            base: nil,
            remote: "y\ny\n",
            localLabel: "HEAD",
            remoteLabel: "feature",
            lineRangeInMerged: 1 ... 4
        )
        let regions: [ConflictRegion] = [
            .text("a\n"),
            .conflict(block),
            .text("b\n"),
        ]
        let layout = MergeRegionVisualLayout.compute(regions: regions)
        #expect(layout.local[0].sourceLineNumber == 1)
        #expect(layout.local[1].sourceLineNumber == 2)
        #expect(layout.local[2].sourceLineNumber == nil)
        #expect(layout.local[3].sourceLineNumber == nil)
        #expect(layout.local[4].sourceLineNumber == 3)
    }
}
