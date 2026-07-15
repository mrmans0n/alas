import Foundation
import Testing
@testable import Alas

@Suite("Diff feedback lane resolver")
struct DiffFeedbackLaneTests {
    @Test func deletedChangedLinesResolveLeft() {
        let anchor = makeAnchor(
            side: .old,
            selectedLines: [selectedLine(side: .old, line: 12, isChange: true)]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .left)
    }

    @Test func addedChangedLinesResolveRight() {
        let anchor = makeAnchor(
            side: .new,
            selectedLines: [selectedLine(side: .new, line: 12, isChange: true)]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .right)
    }

    @Test func contextAndDeletedChangedLinesResolveLeft() {
        let anchor = makeAnchor(
            side: .old,
            selectedLines: [
                selectedLine(side: .unknown, line: 11, isChange: false),
                selectedLine(side: .old, line: 12, isChange: true),
            ]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .left)
    }

    @Test func contextAndAddedChangedLinesResolveRight() {
        let anchor = makeAnchor(
            side: .new,
            selectedLines: [
                selectedLine(side: .unknown, line: 11, isChange: false),
                selectedLine(side: .new, line: 12, isChange: true),
            ]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .right)
    }

    @Test func mixedDeletedAndAddedChangedLinesResolveRight() {
        let anchor = makeAnchor(
            side: .old,
            selectedLines: [
                selectedLine(side: .old, line: 11, isChange: true),
                selectedLine(side: .new, line: 12, isChange: true),
            ]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .right)
    }

    @Test func contextOnlySelectionResolvesToSelectedOldPane() {
        let anchor = makeAnchor(
            side: .old,
            selectedLines: [selectedLine(side: .unknown, line: 12, isChange: false)]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .left)
    }

    @Test func contextOnlySelectionResolvesToSelectedNewPane() {
        let anchor = makeAnchor(
            side: .new,
            selectedLines: [selectedLine(side: .unknown, line: 12, isChange: false)]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .right)
    }

    @Test func unknownRawSelectionDefaultsRight() {
        let anchor = makeAnchor(
            side: .unknown,
            selectedLines: [selectedLine(side: .unknown, line: 12, isChange: true)]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .right)
    }

    @Test func semanticSideResolvesToMatchingLaneAndDefaultsRight() {
        #expect(DiffFeedbackLaneResolver.lane(for: DiffReviewInlineFeedbackSide.old) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: DiffReviewInlineFeedbackSide.new) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: DiffReviewInlineFeedbackSide.unknown) == .right)
    }

    @Test func savedDraftUsesItsSemanticSide() {
        let draft = ReviewDraftComment(
            id: "draft-1",
            sessionID: .localChanges(
                worktreeID: "wt-1",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .old,
            startLine: 12,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Please revisit this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(DiffFeedbackLaneResolver.lane(for: draft) == .left)
    }

    @Test func actionableFeedbackUsesItsAnchorSide() {
        let feedback = DiffReviewInlineFeedback(
            id: "feedback-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please revisit this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(
                path: "Sources/App.swift",
                line: 12,
                side: .new
            ),
            evidenceItemID: "evidence-1"
        )

        #expect(DiffFeedbackLaneResolver.lane(for: feedback) == .right)
    }

    @Test func inlineThreadUsesItsProviderSide() {
        let oldThread = makeThread(id: "thread-old", isOldSide: true)
        let newThread = makeThread(id: "thread-new", isOldSide: false)

        #expect(DiffFeedbackLaneResolver.lane(for: oldThread) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: newThread) == .right)
    }

    @Test func annotationResolvesRight() {
        let annotation = DiffInlineAnnotation(
            id: "annotation-1",
            checkName: "SwiftLint",
            newLine: 12,
            level: .failure,
            message: "Line too long",
            rawDetails: nil
        )

        #expect(DiffFeedbackLaneResolver.lane(for: annotation) == .right)
    }

    @Test func fullLaneRemainsAvailableForLayoutCallers() {
        let lane: DiffFeedbackLane = .full

        #expect(lane == .full)
    }

    private func makeAnchor(
        side: DiffReviewInlineFeedbackSide,
        selectedLines: [DiffReviewLineAnchor.SelectedLine]
    ) -> DiffReviewLineAnchor {
        DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: side,
            line: 12,
            rowIndex: 3,
            selectedLines: selectedLines,
            selectedText: "let value = 1"
        )
    }

    private func selectedLine(
        side: DiffReviewInlineFeedbackSide,
        line: Int,
        isChange: Bool
    ) -> DiffReviewLineAnchor.SelectedLine {
        DiffReviewLineAnchor.SelectedLine(side: side, line: line, isChange: isChange)
    }

    private func makeThread(id: String, isOldSide: Bool) -> DiffInlineCommentThread {
        DiffInlineCommentThread(
            id: id,
            filePath: "Sources/App.swift",
            newLine: 12,
            isOldSide: isOldSide,
            isResolved: false,
            isOutdated: false,
            comments: [DiffInlineComment(id: "\(id)-comment", author: "reviewer", body: "Please revisit this.")]
        )
    }
}
