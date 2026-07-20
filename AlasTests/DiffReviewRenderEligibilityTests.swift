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
    }
}
