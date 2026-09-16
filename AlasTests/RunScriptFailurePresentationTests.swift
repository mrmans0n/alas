import Foundation
import Testing
@testable import Alas

struct RunScriptFailurePresentationTests {
    @Test func bannerUsesNewestFailureAndCountsHiddenOnes() {
        let older = failure(id: "older", scriptName: "Build", exitCode: 1, completedAt: Date(timeIntervalSince1970: 1))
        let newer = failure(id: "newer", scriptName: "Test", exitCode: 2, completedAt: Date(timeIntervalSince1970: 2))

        let banner = RunScriptFailureBannerPresentation(failures: [older, newer])

        #expect(banner?.failure.id == "newer")
        #expect(banner?.title == "Test failed with exit code 2")
        #expect(banner?.overflowText == "1 more")
    }

    private func failure(
        id: String = "failure",
        scriptName: String = "Dev",
        exitCode: Int32 = 1,
        completedAt: Date = Date()
    ) -> RunScriptFailure {
        RunScriptFailure(
            id: id,
            runID: id,
            scriptKey: scriptName,
            scriptName: scriptName,
            worktreeID: "wt",
            branch: "main",
            exitCode: exitCode,
            completedAt: completedAt
        )
    }
}
