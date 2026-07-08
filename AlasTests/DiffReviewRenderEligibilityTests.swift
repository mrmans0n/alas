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
    }
}
