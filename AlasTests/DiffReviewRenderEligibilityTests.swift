import Foundation
import Testing
@testable import Alas

struct DiffReviewRenderEligibilityTests {
    private func id(_ path: String) -> DiffReviewFileID {
        DiffReviewFileID(namespace: "unstaged", path: path)
    }

    @Test func keepsWindowAroundSelectedFileEligibleForRendering() {
        let files = (0..<20).map { id("f\($0).swift") }

        let eligible = DiffReviewRenderEligibility.fileIDs(
            ordered: files,
            selected: files[10],
            required: [],
            neighborCount: 2
        )

        #expect(eligible == Set(files[8...12]))
    }

    @Test func includesRequiredFilesOutsideSelectedWindow() {
        let files = (0..<20).map { id("f\($0).swift") }

        let eligible = DiffReviewRenderEligibility.fileIDs(
            ordered: files,
            selected: files[10],
            required: [files[0], files[19]],
            neighborCount: 1
        )

        #expect(eligible == Set([files[0], files[9], files[10], files[11], files[19]]))
    }

    @Test func fallsBackToFirstFileWhenSelectionIsUnavailable() {
        let files = (0..<20).map { id("f\($0).swift") }

        let eligible = DiffReviewRenderEligibility.fileIDs(
            ordered: files,
            selected: id("missing.swift"),
            required: [],
            neighborCount: 2
        )

        #expect(eligible == Set(files[0...2]))
    }

    @Test func preservesEmptySessions() {
        #expect(DiffReviewRenderEligibility.fileIDs(ordered: [], selected: nil, required: []).isEmpty)
    }
}
