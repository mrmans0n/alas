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
            side: .unknown,
            selectedLines: [
                selectedLine(side: .unknown, line: 11, isChange: false),
                selectedLine(side: .old, line: 12, isChange: true),
            ]
        )

        #expect(DiffFeedbackLaneResolver.lane(for: anchor) == .left)
    }

    @Test func contextAndAddedChangedLinesResolveRight() {
        let anchor = makeAnchor(
            side: .unknown,
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

    @Test func savedDraftUsesItsSemanticSideAndDefaultsUnknownRight() {
        #expect(DiffFeedbackLaneResolver.lane(for: makeDraft(side: .old)) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: makeDraft(side: .new)) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: makeDraft(side: .unknown)) == .right)
    }

    @Test func actionableFeedbackUsesItsAnchorSideAndDefaultsUnknownRight() {
        #expect(DiffFeedbackLaneResolver.lane(for: makeFeedback(side: .old)) == .left)
        #expect(DiffFeedbackLaneResolver.lane(for: makeFeedback(side: .new)) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: makeFeedback(side: .unknown)) == .right)
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

    @Test func lanesProvideStableRawValuesAndHashabilityForLayoutMarkers() {
        let lanes: Set<DiffFeedbackLane> = [.left, .right, .full]

        #expect(lanes.count == 3)
        #expect(DiffFeedbackLane.left.rawValue == "left")
        #expect(DiffFeedbackLane.right.rawValue == "right")
        #expect(DiffFeedbackLane.full.rawValue == "full")
    }

    @Test func laneFramesMatchTheDiffPaneDividerMath() {
        #expect(DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: 901,
            layoutMode: .split,
            lane: .left,
            gutterWidth: 42
        ) == CGRect(x: 42, y: 0, width: 408, height: 0))
        #expect(DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: 901,
            layoutMode: .split,
            lane: .right,
            gutterWidth: 42
        ) == CGRect(x: 493, y: 0, width: 408, height: 0))
        #expect(DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: 901,
            layoutMode: .stacked,
            lane: .right,
            gutterWidth: 42
        ) == CGRect(x: 42, y: 0, width: 859, height: 0))
    }

    @Test func gutterThicknessUsesExistingMinimumAndExpandsForWideLabels() {
        #expect(DiffPaneLineNumberGutterGeometry.thickness(labels: ["1", "22"]) == 42)
        #expect(DiffPaneLineNumberGutterGeometry.thickness(labels: ["1234567890"]) > 42)
    }

    @Test func labelProjectionUsesTheActivePane() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [.init(
                header: "@@ -9,1 +99,1 @@",
                oldStart: 9,
                newStart: 99,
                lines: [
                    .init(kind: .delete, text: "old", oldNumber: 9, newNumber: nil),
                    .init(kind: .add, text: "new", oldNumber: nil, newNumber: 99),
                ]
            )]),
            filePath: "Sources/App.swift"
        )
        let rows = try #require(model.groups.first?.rows)

        #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .split, lane: .left) == ["9"])
        #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .split, lane: .right) == ["99"])
        #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .split, lane: .full) == ["99"])
        #expect(DiffFeedbackLineLabels.labels(for: rows, layoutMode: .stacked, lane: .right) == ["9", "99"])
    }

    @Test func laneFramesRemainNonnegativeAtNarrowAndZeroWidths() {
        for width: CGFloat in [0, 0.5, 1, 41, 42, 84] {
            for layoutMode in DiffLayoutMode.allCases {
                for lane in [DiffFeedbackLane.left, .right, .full] {
                    let frame = DiffFeedbackLaneGeometry.contentFrame(
                        containerWidth: width,
                        layoutMode: layoutMode,
                        lane: lane,
                        gutterWidth: 42
                    )

                    #expect(frame.minX >= 0)
                    #expect(frame.width >= 0)
                    #expect(frame.maxX <= max(width, 0))
                }
            }
        }
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

    private func makeDraft(side: DiffReviewInlineFeedbackSide) -> ReviewDraftComment {
        ReviewDraftComment(
            id: "draft-\(side.rawValue)",
            sessionID: .localChanges(
                worktreeID: "wt-1",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: side,
            startLine: 12,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Please revisit this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeFeedback(side: DiffReviewInlineFeedbackSide) -> DiffReviewInlineFeedback {
        DiffReviewInlineFeedback(
            id: "feedback-\(side.rawValue)",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please revisit this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(
                path: "Sources/App.swift",
                line: 12,
                side: side
            ),
            evidenceItemID: "evidence-\(side.rawValue)"
        )
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
