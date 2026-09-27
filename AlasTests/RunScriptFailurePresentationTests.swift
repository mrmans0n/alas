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

    private static let excerpt = FailureLogExcerpt(
        lines: [.init(number: 2, text: "a"), .init(number: 3, text: "error: b"), .init(number: 9, text: "FAILED")],
        matchedErrors: true,
        truncated: false
    )
    private static let brief = RunFailureBrief(summary: "Net tests failed to compile.", cause: "c", checks: ["k"])

    @Test(arguments: [
        (RunFailureBriefCoordinator.State?.none, String?.none),
        (.generating(RunScriptFailurePresentationTests.excerpt), "Summarizing on-device…"),
        (.ready(RunScriptFailurePresentationTests.excerpt, RunScriptFailurePresentationTests.brief), "Net tests failed to compile."),
        (.unavailable(RunScriptFailurePresentationTests.excerpt), nil),
    ])
    func bannerDetailFollowsTheBriefState(state: RunFailureBriefCoordinator.State?, expected: String?) {
        let banner = RunScriptFailureBannerPresentation(failure: failure(), brief: state)

        #expect(banner.title == "Dev failed with exit code 1")
        #expect(banner.detail == expected)
    }

    @Test
    func briefSectionMarksGapsBetweenNonContiguousLinesAndLabelsTheSource() throws {
        let section = try #require(RunFailureBriefPresentation(state: .generating(Self.excerpt)))

        #expect(section.observedTitle == "Observed errors")
        #expect(section.rows == [.line(number: 2, text: "a"), .line(number: 3, text: "error: b"), .gap, .line(number: 9, text: "FAILED")])
        #expect(section.suggestion == .generating)

        let tail = FailureLogExcerpt(lines: Self.excerpt.lines, matchedErrors: false, truncated: false)
        #expect(RunFailureBriefPresentation(state: .unavailable(tail))?.observedTitle == "Last lines of output")
        #expect(RunFailureBriefPresentation(state: .unavailable(nil)) == nil)
        #expect(RunFailureBriefPresentation(state: nil) == nil)
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
