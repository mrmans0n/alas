import Testing
@testable import Alas

struct RightPaneStateReviewLoopPushTests {
    @Test func pushFailureMessagePrefersStderr() {
        let result = ProcessResult(
            exitCode: 128,
            stdout: "stdout fallback",
            stderr: " fatal: no upstream \n"
        )

        #expect(RightPaneState.reviewLoopPushFailureMessage(result) == "fatal: no upstream")
    }

    @Test func pushFailureMessageUsesStdoutWhenStderrIsEmpty() {
        let result = ProcessResult(
            exitCode: 1,
            stdout: " rejected by remote \n",
            stderr: ""
        )

        #expect(RightPaneState.reviewLoopPushFailureMessage(result) == "rejected by remote")
    }

    @Test func pushFailureMessageFallsBackToExitCode() {
        let result = ProcessResult(exitCode: 1, stdout: "", stderr: "")

        #expect(RightPaneState.reviewLoopPushFailureMessage(result) == "git push failed with exit code 1.")
    }
}
