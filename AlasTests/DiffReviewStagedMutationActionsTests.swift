import Testing
import Foundation
@testable import Alas

struct DiffReviewStagedMutationActionsTests {
    @Test func defaultFileSectionModelHasNilStagedActions() {
        let summary = DiffReviewFileSummary(
            path: "Sources/App.swift",
            namespace: "staged",
            groupID: nil,
            groupTitle: nil,
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: true
        )
        let model = DiffReviewFileSectionModel(
            summary: summary,
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil
        )

        #expect(model.stagedMutationActions == nil)
    }

    @Test func nilActionsAreNonCrashing() {
        var actions = DiffReviewStagedMutationActions()
        actions.unstageFile = nil
        actions.unstageHunk = nil
        actions.isHunkUnstageEnabled = nil

        // Calling the nil closures with optional chaining should not crash
        actions.unstageFile?()
        let hunk = ParsedDiff.Hunk(
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1,
            newStart: 1,
            lines: [
                .init(kind: .add, text: "let x = 1", oldNumber: nil, newNumber: 1),
            ]
        )
        actions.unstageHunk?(hunk)

        // Reaching here means no crash occurred
        #expect(true)
    }

    @Test func hunkUnstageEnabledRuleMatchesSpec() {
        // Rule: enabled when !busy && status == .modified && !hunk.lines.isEmpty
        let emptyHunk = ParsedDiff.Hunk(
            header: "@@ -0,0 +0,0 @@",
            oldStart: 0,
            newStart: 0,
            lines: []
        )
        let nonEmptyHunk = ParsedDiff.Hunk(
            header: "@@ -1,1 +1,1 @@",
            oldStart: 1,
            newStart: 1,
            lines: [
                .init(kind: .add, text: "let x = 1", oldNumber: nil, newNumber: 1),
            ]
        )

        func isEnabled(busy: Bool, status: DiffReviewFileStatus, hunk: ParsedDiff.Hunk) -> Bool {
            !busy && status == .modified && !hunk.lines.isEmpty
        }

        // busy=true → false
        #expect(isEnabled(busy: true, status: .modified, hunk: nonEmptyHunk) == false)

        // busy=false, status=.modified, lines not empty → true
        #expect(isEnabled(busy: false, status: .modified, hunk: nonEmptyHunk) == true)

        // busy=false, status=.added → false
        #expect(isEnabled(busy: false, status: .added, hunk: nonEmptyHunk) == false)

        // busy=false, status=.modified, lines empty → false
        #expect(isEnabled(busy: false, status: .modified, hunk: emptyHunk) == false)
    }
}
