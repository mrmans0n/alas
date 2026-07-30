import Foundation
import Testing
@testable import Alas

struct DiffReviewRenderEligibilityTests {
    private func id(_ path: String) -> DiffReviewFileID {
        DiffReviewFileID(namespace: "unstaged", path: path)
    }

    @Test func keepsEveryLoadedFileEligibleForRendering() {
        let files = (0..<20).map { id("f\($0).swift") }

        let eligible = DiffReviewRenderEligibility.fileIDs(ordered: files)

        #expect(eligible == Set(files))
    }

    @Test func preservesEmptySessions() {
        #expect(DiffReviewRenderEligibility.fileIDs(ordered: []).isEmpty)
        #expect(DiffReviewRenderEligibility.renderRows(ordered: []).isEmpty)
    }

    @Test func renderRowsContainOnlyIndicesAndStableIDs() {
        let files = [
            id("A.swift"),
            id("B.swift"),
            id("C.swift"),
        ]

        let rows = DiffReviewRenderEligibility.renderRows(ordered: files)

        #expect(rows.map(\.index) == [0, 1, 2])
        #expect(rows.map(\.id) == files)
        #expect(rows.map(\.showsBottomSpacing) == [true, true, false])
    }

    @Test func legacyRenderRowsKeepEveryFileAutomaticallyEligible() {
        let files = [id("A.swift"), id("B.swift")]

        let rows = DiffReviewRenderEligibility.renderRows(ordered: files)

        #expect(rows.map(\.automaticallyRendersDiff) == [true, true])
    }

    @Test func aggregateEligibilityIncludesRowsThatExactlyFillTheCap() {
        let files = [id("A.swift"), id("B.swift"), id("C.swift")]

        let rows = DiffReviewRenderEligibility.renderRows(
            ordered: files,
            renderedRowCounts: [2, 3, 1],
            maxAutomaticallyRenderedRows: 5
        )

        #expect(rows.map(\.automaticallyRendersDiff) == [true, true, false])
    }

    @Test func aggregateEligibilityDefersTheFirstNormalRowBeyondTheRemainingCapAndLaterNormalRows() {
        let files = [id("A.swift"), id("B.swift"), id("C.swift")]

        let rows = DiffReviewRenderEligibility.renderRows(
            ordered: files,
            renderedRowCounts: [3, 3, 1],
            maxAutomaticallyRenderedRows: 5
        )

        #expect(rows.map(\.automaticallyRendersDiff) == [true, false, false])
    }

    @Test func aggregateEligibilityDoesNotChargeMissingOrOversizedRowsToTheCap() {
        let files = [id("A.swift"), id("B.swift"), id("C.swift"), id("D.swift"), id("E.swift")]

        let rows = DiffReviewRenderEligibility.renderRows(
            ordered: files,
            renderedRowCounts: [2, nil, DiffReviewRenderBudget.maxRenderedRows + 1, 3, 1],
            maxAutomaticallyRenderedRows: 5
        )

        #expect(rows.map(\.automaticallyRendersDiff) == [true, true, true, true, false])
    }
}
