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

    @Test func detailPrefersCapturedOutputAndFallsBackWhenUnavailable() {
        let withOutput = RunScriptFailureDetailPresentation(failure: failure(
            capturedOutput: .available(text: "stderr\n", truncated: true)
        ))
        let withoutOutput = RunScriptFailureDetailPresentation(failure: failure(capturedOutput: .unavailable))

        #expect(withOutput.outputText == "stderr\n")
        #expect(withOutput.outputFooter == "Output truncated")
        #expect(!withOutput.completedText.isEmpty)
        #expect(withoutOutput.outputText == "Output could not be captured.")
        #expect(withoutOutput.outputFooter == nil)
    }

    private func failure(
        id: String = "failure",
        scriptName: String = "Dev",
        exitCode: Int32 = 1,
        completedAt: Date = Date(),
        capturedOutput: RunScriptCapturedOutput = .available(text: "oops\n", truncated: false)
    ) -> RunScriptFailure {
        RunScriptFailure(
            id: id,
            runID: id,
            scriptKey: scriptName,
            scriptName: scriptName,
            worktreeID: "wt",
            branch: "main",
            exitCode: exitCode,
            completedAt: completedAt,
            capturedOutput: capturedOutput
        )
    }
}
