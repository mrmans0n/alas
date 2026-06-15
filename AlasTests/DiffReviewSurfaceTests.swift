import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffReviewSurfaceTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func railRendersUngroupedCommitSessionWithFileRowsAndNoSourceHeader() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", additions: 4, deletions: 1),
            summary(path: "Tests/BetaTests.swift", status: .added, additions: 12, deletions: 0),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)
        var selected = files[0].id
        var collapsed = false

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[1].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-commit", in: controller.view) == nil)
        #expect(accessibilityLabel(in: controller.view, containing: "AlphaView.swift") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "BetaTests.swift") != nil)
    }

    @Test func railRendersGroupedSessionsWithSourceHeaders() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", namespace: "unstaged", groupID: "unstaged", groupTitle: "Unstaged"),
            summary(path: "Sources/App/BetaView.swift", namespace: "staged", groupID: "staged", groupTitle: "Staged", status: .added),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: true)
        var selected = files[0].id
        var collapsed = false

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-unstaged", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-source-staged", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-row-\(files[1].id.rawValue)", in: controller.view) != nil)
    }

    @Test func collapsedRailKeepsSelectableMarkers() {
        let files = [
            summary(path: "Sources/App/AlphaView.swift", additions: 4, deletions: 1),
            summary(path: "Tests/BetaTests.swift", status: .added, additions: 12, deletions: 0),
        ]
        let session = DiffReviewSessionModel(files: files, groupsEnabled: false)
        var selected = files[1].id
        var collapsed = true

        let view = DiffReviewRail(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            onSelectFile: { selected = $0 }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 60, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[0].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-\(files[1].id.rawValue)", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-rail-marker-selected-\(files[1].id.rawValue)", in: controller.view) != nil)
    }

    @Test func railSelectedFileRowsUseSidebarSelectionTreatment() {
        #expect(DiffReviewRailSelectedRowStyle.backgroundToken == "bg-4")
        #expect(DiffReviewRailSelectedRowStyle.fileDepthIndent == 6)
        #expect(DiffReviewRailSelectedRowStyle.accentRailWidth == 3)
        #expect(DiffReviewRailSelectedRowStyle.accentRailHeight == 14)
        #expect(DiffReviewRailSelectedRowStyle.accentRailXOffset == 2)
        #expect(DiffReviewRailSelectedRowStyle.cornerRadius == 6)
        #expect(DiffReviewRailSelectedRowStyle.contentLeadingPadding == 6)
    }

    @Test func fileSectionEmbedsDiffPaneWithoutToolbarAndShowsOpenFile() {
        let file = DiffReviewFileSectionModel(
            summary: summary(
                path: "Sources/App/AlphaView.swift",
                namespace: "unstaged",
                groupID: "unstaged",
                groupTitle: "Unstaged",
                additions: 1,
                deletions: 1
            ),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: {},
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
        #expect(DiffReviewFileSectionActions.openFileButtonTitle(for: file) == "Open File")
        #expect(accessibilityLabel(in: controller.view, containing: "UNSTAGED") != nil)
    }

    @Test func fileSectionAcceptsLSPContextWithoutChangingLayout() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App/AlphaView.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let context = DiffPaneLSPContext(
            worktreeId: "worktree-1",
            worktreeRoot: URL(fileURLWithPath: "/tmp/worktree"),
            relativePath: "Sources/App/AlphaView.swift",
            language: "swift",
            lsp: manager,
            openTarget: { _, _, _ in }
        )

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "SF Mono",
            codeFontSize: 13,
            showsSourceBadge: false,
            lspContext: context
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)
        let textViews = allSubviews(of: controller.view).compactMap { $0 as? DiffPaneCodeTextView }

        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
        #expect(textViews.contains { $0.hasLSPContextForTesting && $0.allowedLSPSideForTesting == .new })
        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
    }

    @Test func fileSectionRendersFileLevelInlineFeedbackBelowHeader() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = [
            DiffReviewInlineFeedback(
                id: "thread-file",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Please review this file.",
                status: .actionable,
                providerURL: URL(string: "https://github.com/thread-file")!,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
                evidenceItemID: "thread-file"
            ),
        ]
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-file", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "GitHub") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "reviewer") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Please review this file.") != nil)
    }

    @Test func fileSectionHighlightsFocusedInlineFeedbackAndShowsAvailableActions() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/thread")!,
            anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let actions = DiffReviewInlineFeedbackActions(
            availability: { _, _ in
                DiffReviewInlineFeedbackActionAvailability(
                    canOpenProvider: true,
                    canCopyContext: true,
                    canSendToAgent: false
                )
            },
            openProvider: { _, _ in },
            copyContext: { _, _ in },
            sendToAgent: { _, _ in }
        )

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: [feedback],
            focusedFeedbackID: "thread-1",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            inlineFeedbackActions: actions,
            onSelectInlineFeedback: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-open-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-copy-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-send-thread-1", in: controller.view) == nil)
        #expect(subviews(withAccessibilityIdentifier: "diff-review-inline-feedback-open-thread-1", in: controller.view).count <= 1)
        #expect(subviews(withAccessibilityIdentifier: "diff-review-inline-feedback-copy-thread-1", in: controller.view).count <= 1)
    }

    @Test func focusedInlineFeedbackPastDisplayCapRemainsVisibleWithMoreRow() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path, lineAnchored: false)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            focusedFeedbackID: "thread-5",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 600)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-2", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-3", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-4", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-5", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-5", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "+1 more feedback") != nil)
    }

    @Test func inlineFeedbackScrollTargetPastDisplayCapRemainsVisible() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path, lineAnchored: false)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            inlineFeedbackScrollTargetID: "thread-5",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 600)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-5", in: controller.view) != nil)
    }

    @Test func inlineFeedbackCardInteractionRoutesSelectionAndActionsIndependently() {
        let feedback = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update this.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/thread")!,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
            evidenceItemID: "thread-1"
        )
        var selectedFeedbackID: String?
        var openedFeedbackID: String?
        var copiedFeedbackID: String?
        var sentFeedbackID: String?

        DiffReviewInlineFeedbackCardInteraction.open(feedback) {
            openedFeedbackID = $0.id
        }
        DiffReviewInlineFeedbackCardInteraction.copy(feedback) {
            copiedFeedbackID = $0.id
        }
        DiffReviewInlineFeedbackCardInteraction.send(feedback) {
            sentFeedbackID = $0.id
        }

        #expect(selectedFeedbackID == nil)
        #expect(openedFeedbackID == "thread-1")
        #expect(copiedFeedbackID == "thread-1")
        #expect(sentFeedbackID == "thread-1")

        DiffReviewInlineFeedbackCardInteraction.select(feedback) {
            selectedFeedbackID = $0.id
        }

        #expect(selectedFeedbackID == "thread-1")
    }

    @Test func renderWindowKeepsInlineFeedbackScrollTargetFileRendered() {
        let fileScrollTarget = DiffReviewFileID(namespace: "commit", path: "Selected.swift")
        let inlineTarget = DiffReviewFileID(namespace: "commit", path: "InlineTarget.swift")
        let command = DiffReviewInlineFeedbackScrollCommand(
            feedbackID: "thread-inline",
            fileID: inlineTarget,
            generation: 1
        )

        #expect(
            DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: fileScrollTarget,
                inlineFeedbackScrollCommand: nil
            ) == fileScrollTarget
        )
        #expect(
            DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: nil,
                inlineFeedbackScrollCommand: command
            ) == inlineTarget
        )
    }

    @Test func fileSectionCapsInlineFeedbackCardsWithMoreRow() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path, lineAnchored: false)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            inlineFeedback: feedback,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-1", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-2", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-3", in: controller.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-4", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-thread-5", in: controller.view) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-more", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "+2 more feedback") != nil)
    }

    @Test func inlineFeedbackPlacementGroupsLineAnchoredItemsByMatchingHunk() throws {
        let model = displayModel()
        let firstGroup = try #require(model.groups.first)
        let feedback = [
            DiffReviewInlineFeedback(
                id: "thread-new-line",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Review this new line.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 2, side: .new),
                evidenceItemID: "thread-new-line"
            ),
            DiffReviewInlineFeedback(
                id: "thread-file",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Review the whole file.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
                evidenceItemID: "thread-file"
            ),
            DiffReviewInlineFeedback(
                id: "thread-unmatched",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Review a line outside the diff.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 42, side: .new),
                evidenceItemID: "thread-unmatched"
            ),
        ]

        let placement = DiffReviewInlineFeedbackPlacement.position(feedback, in: model.groups)

        #expect(placement.byGroupID[firstGroup.id]?.map(\.id) == ["thread-new-line"])
        #expect(placement.fileLevel.map(\.id) == ["thread-file", "thread-unmatched"])
    }

    @Test func localDraftCommentsPositionAtExactMatchingRows() throws {
        let model = displayModel()
        let comment = draftComment(id: "draft-line", path: "A.swift", side: .new, startLine: 2)

        let placement = ReviewDraftCommentPlacement.position([comment], in: model.groups)

        #expect(
            placement.byRowAnchor[ReviewDraftCommentPlacement.RowKey(side: .new, line: 2)]?.map(\.id) == ["draft-line"]
        )
        #expect(placement.fileLevel.isEmpty)
    }

    @Test func unmatchedLocalDraftCommentsFallBackToFileLevel() {
        let model = displayModel()
        let comment = draftComment(id: "draft-unmatched", path: "A.swift", side: .new, startLine: 99)

        let placement = ReviewDraftCommentPlacement.position([comment], in: model.groups)

        #expect(placement.byRowAnchor.isEmpty)
        #expect(placement.fileLevel.map(\.id) == ["draft-unmatched"])
    }

    @Test func localDraftCommentsSegmentSameHunkByExactRow() throws {
        let model = displayModel()
        let group = try #require(model.groups.first)
        let firstLine = draftComment(id: "draft-first", path: "A.swift", side: .new, startLine: 1)
        let secondLine = draftComment(id: "draft-second", path: "A.swift", side: .new, startLine: 2)
        let placement = ReviewDraftCommentPlacement.position([secondLine, firstLine], in: model.groups)

        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(segments.items.count == 2)
        #expect(segments.items[0].rows.map(\.id) == [group.rows[0].id])
        #expect(segments.items[0].draftComments.map(\.id) == ["draft-first"])
        #expect(segments.items[1].rows.map(\.id) == [group.rows[1].id])
        #expect(segments.items[1].draftComments.map(\.id) == ["draft-second"])
    }

    @Test func localDraftCommentsOnCollapsedRowsAttachToCollapsedParent() throws {
        let hiddenLine = diffLine(
            id: "hidden-new",
            side: .new,
            newLine: 12,
            text: "let hidden = true"
        )
        let collapsedParent = DiffDisplayRow(
            id: "collapsed-parent",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: 1,
            collapsedRows: [
                DiffDisplayRow(
                    id: "hidden-row",
                    kind: .context,
                    old: nil,
                    new: hiddenLine,
                    collapsedLineCount: 0
                ),
            ]
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -10,3 +10,3 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [collapsedParent]
        )
        let comment = draftComment(id: "draft-collapsed", path: "A.swift", side: .new, startLine: 12)

        let placement = ReviewDraftCommentPlacement.position([comment], in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(placement.fileLevel.isEmpty)
        #expect(placement.byRowAnchor[ReviewDraftCommentPlacement.RowKey(side: .new, line: 12)]?.map(\.id) == ["draft-collapsed"])
        #expect(segments.items.count == 1)
        #expect(segments.items[0].rows.map(\.id) == ["collapsed-parent"])
        #expect(segments.items[0].draftComments.map(\.id) == ["draft-collapsed"])
    }

    @Test func draftPlacementIndexesCollapsedChildRows() {
        let line = diffLine(id: "old-hidden", side: .old, oldLine: 7, text: "let old = true")
        let row = DiffDisplayRow(
            id: "collapsed-parent",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: 1,
            collapsedRows: [
                DiffDisplayRow(
                    id: "old-hidden-row",
                    kind: .context,
                    old: line,
                    new: nil,
                    collapsedLineCount: 0
                ),
            ]
        )

        #expect(ReviewDraftCommentPlacement.visibleRowKeys(in: row).isEmpty)
        #expect(ReviewDraftCommentPlacement.allRowKeys(in: row) == [
            ReviewDraftCommentPlacement.RowKey(side: .old, line: 7),
            ReviewDraftCommentPlacement.RowKey(side: .unknown, line: 7),
        ])
    }

    @Test func localDraftCommentsWithUnknownSideMatchContextRows() throws {
        let model = displayModel()
        let comment = draftComment(id: "draft-unknown", path: "A.swift", side: .unknown, startLine: 1)

        let placement = ReviewDraftCommentPlacement.position([comment], in: model.groups)
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: try #require(model.groups.first),
            placement: placement,
            pendingAnchor: nil
        )

        #expect(placement.fileLevel.isEmpty)
        #expect(
            placement.byRowAnchor[ReviewDraftCommentPlacement.RowKey(side: .unknown, line: 1)]?.map(\.id)
                == ["draft-unknown"]
        )
        #expect(segments.items.first?.draftComments.map(\.id) == ["draft-unknown"])
    }

    @Test func localDraftCommentsWithUnknownSideDoNotDuplicateAcrossShiftedContextRows() {
        let firstRow = DiffDisplayRow(
            id: "row-1",
            kind: .context,
            old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "one"),
            new: diffLine(id: "new-2", side: .new, newLine: 2, text: "two"),
            collapsedLineCount: 0
        )
        let secondRow = DiffDisplayRow(
            id: "row-2",
            kind: .context,
            old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "two"),
            new: diffLine(id: "new-3", side: .new, newLine: 3, text: "three"),
            collapsedLineCount: 0
        )
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,2 +2,2 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [firstRow, secondRow]
        )
        let comment = draftComment(id: "draft-shifted", path: "A.swift", side: .unknown, startLine: 2)

        let placement = ReviewDraftCommentPlacement.position([comment], in: [group])
        let segments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(segments.items.flatMap(\.draftComments).map(\.id) == ["draft-shifted"])
    }

    @Test func localDraftCommentsWithUnknownSideDoNotDuplicateAcrossMatchingHunks() {
        let firstGroup = DiffDisplayGroup(
            id: "first-group",
            header: "@@ -1,1 +2,1 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [
                DiffDisplayRow(
                    id: "first-row",
                    kind: .context,
                    old: diffLine(id: "first-old", side: .old, oldLine: 1, text: "one"),
                    new: diffLine(id: "first-new", side: .new, newLine: 2, text: "two"),
                    collapsedLineCount: 0
                ),
            ]
        )
        let secondGroup = DiffDisplayGroup(
            id: "second-group",
            header: "@@ -2,1 +3,1 @@",
            sourceHunk: parsedDiff().hunks[0],
            rows: [
                DiffDisplayRow(
                    id: "second-row",
                    kind: .context,
                    old: diffLine(id: "second-old", side: .old, oldLine: 2, text: "two"),
                    new: diffLine(id: "second-new", side: .new, newLine: 3, text: "three"),
                    collapsedLineCount: 0
                ),
            ]
        )
        let comment = draftComment(id: "draft-cross-hunk", path: "A.swift", side: .unknown, startLine: 2)
        let placement = ReviewDraftCommentPlacement.position([comment], in: [firstGroup, secondGroup])

        let firstSegments = ReviewDraftCommentRowSegmentation.segments(
            for: firstGroup,
            placement: placement,
            pendingAnchor: nil
        )
        let secondSegments = ReviewDraftCommentRowSegmentation.segments(
            for: secondGroup,
            placement: placement,
            pendingAnchor: nil
        )

        #expect(placement.groupIDByCommentID["draft-cross-hunk"] == "first-group")
        #expect(firstSegments.items.flatMap(\.draftComments).map(\.id) == ["draft-cross-hunk"])
        #expect(secondSegments.items.flatMap(\.draftComments).isEmpty)
    }

    @Test func fileSectionRendersVisibleLocalDraftCommentCard() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-visible", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-draft-visible", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Local draft") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Please revisit this line.") != nil)
    }

    @Test func fileSectionDraftCommentCardCanDismissComment() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-dismiss-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var dismissedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: true,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            dismiss: { dismissedID = $0.id }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-dismiss-draft-dismiss-inline",
            in: controller.view
        ))
        #expect(dismissedID == "draft-dismiss-inline")
    }

    @Test func fileSectionDraftCommentCardCanPublishProviderComment() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil
        )
        let comment = draftComment(id: "draft-publish-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var publishedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false,
                    canPublishProvider: true
                )
            },
            publishProvider: { publishedID = $0.id }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-publish-draft-publish-inline",
            in: controller.view
        ))
        #expect(publishedID == "draft-publish-inline")
    }

    @Test func fileSectionDraftCommentCardUsesProvidedReviewTargetForPromptActions() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let target = ReviewFeedbackTarget(
            title: "Review working tree",
            repositoryPath: "/repo",
            providerDescription: "GitHub #123",
            sourceDescription: "Review Changes"
        )
        let comment = draftComment(id: "draft-target-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let recorder = ReviewBundleActionRecorder()
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: true,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            copyPrompt: { recorder.copied = $0 }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions,
            reviewFeedbackTarget: target
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-copy-draft-target-inline",
            in: controller.view
        ))
        #expect(recorder.copied?.target == target)
        #expect(recorder.copied?.comments == [comment])
    }

    @Test func fileSectionDraftCommentCardDoesNotFireDisabledSendAction() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(
            id: "draft-disabled-send-inline",
            fileID: file.id,
            path: file.summary.path,
            side: .new,
            startLine: 2,
            state: .resolved
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: true,
                    canSendToAgent: false
                )
            },
            agentTargets: { [.newChat(agentID: "codex", title: "Codex")] },
            sendToAgent: { _, _ in Issue.record("disabled send action fired") }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)

        #expect(!pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-send-draft-disabled-send-inline",
            in: controller.view
        ))
    }

    @Test func fileSectionDraftCommentEditorDoesNotKeepCardSelectionButtonActive() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-edit-inline", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var selectedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: true,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            }
        )

        let view = DiffReviewFileSection(
            file: file,
            draftComments: [comment],
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: false,
            draftCommentActions: actions,
            onSelectDraftComment: { selectedID = $0.id }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 500)
        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "diff-review-draft-comment-action-edit-draft-edit-inline",
            in: controller.view
        ))
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-draft-comment-action-save-draft-edit-inline", in: controller.view) != nil)
        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-draft-comment-select-draft-edit-inline", in: controller.view))
        #expect(selectedID == nil)
    }

    @Test func inlineFeedbackContextFormatterIncludesReviewMetadata() {
        let file = summary(path: "Sources/App.swift")
        let item = DiffReviewInlineFeedback(
            id: "thread-1",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Please update `configId`.",
            status: .actionable,
            providerURL: URL(string: "https://github.com/org/repo/pull/1#discussion_r1"),
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: 56, side: .new),
            evidenceItemID: "thread-1"
        )

        let context = DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file)

        #expect(context.contains("GitHub feedback"))
        #expect(context.contains("Author: reviewer"))
        #expect(context.contains("File: Sources/App.swift"))
        #expect(context.contains("Line: 56"))
        #expect(context.contains("Side: new"))
        #expect(context.contains("Status: actionable"))
        #expect(context.contains("URL: https://github.com/org/repo/pull/1#discussion_r1"))
        #expect(context.contains("Please update `configId`."))
    }

    @Test func inlineFeedbackContextFormatterIncludesDistinctAnchorPath() {
        let file = summary(path: "Sources/NewApp.swift", originalPath: "Sources/OldApp.swift")
        let item = DiffReviewInlineFeedback(
            id: "thread-rename",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Check the old-side mapping.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/OldApp.swift", line: 12, side: .old),
            evidenceItemID: "thread-rename"
        )

        let context = DiffReviewInlineFeedbackContextFormatter.format(item: item, file: file)

        #expect(context.contains("File: Sources/NewApp.swift"))
        #expect(context.contains("Anchor file: Sources/OldApp.swift"))
        #expect(context.contains("Line: 12"))
        #expect(context.contains("Side: old"))
    }

    @Test func inlineFeedbackScrollCommandAdvancesForRepeatedSelections() {
        let fileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App.swift")
        var controller = DiffReviewInlineFeedbackScrollController()

        let first = controller.command(feedbackID: "thread-1", fileID: fileID)
        let second = controller.command(feedbackID: "thread-1", fileID: fileID)

        #expect(first.feedbackID == "thread-1")
        #expect(first.fileID == fileID)
        #expect(second.generation == first.generation + 1)
        #expect(second.targetID == DiffReviewInlineFeedbackTargetID(fileID: fileID, feedbackID: "thread-1"))
    }

    @Test func inlineFeedbackTargetIDDoesNotCollideForAmbiguousFlattenedStrings() {
        let firstFileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App-a")
        let secondFileID = DiffReviewFileID(namespace: "github-pr", path: "Sources/App")

        let first = DiffReviewInlineFeedbackTargetID(fileID: firstFileID, feedbackID: "b")
        let second = DiffReviewInlineFeedbackTargetID(fileID: secondFileID, feedbackID: "a-b")

        #expect("\(firstFileID.rawValue)-b" == "\(secondFileID.rawValue)-a-b")
        #expect(first != second)
    }

    @MainActor
    @Test func inlineFeedbackMarkdownRendersCommonReviewMarkup() throws {
        let rendered = NSAttributedString(
            DiffReviewInlineFeedbackMarkdown.render("Use **bold** and `configId`, then see [docs](https://example.com/docs).")
        )

        #expect(rendered.string == "Use bold and configId, then see docs.")

        let linkRange = (rendered.string as NSString).range(of: "docs")
        try #require(linkRange.location != NSNotFound)
        let url = rendered.attribute(NSAttributedString.Key.link, at: linkRange.location, effectiveRange: nil) as? URL
        #expect(url?.absoluteString == "https://example.com/docs")
    }

    @MainActor
    @Test func inlineFeedbackMarkdownPlainTextStripsDelimitersForAccessibility() {
        let plain = DiffReviewInlineFeedbackMarkdown.plainText("Use **bold** and `configId`.")

        #expect(plain == "Use bold and configId.")
    }

    @Test func textDocumentViewClearsInactivePaneLSPContextWhenLayoutChanges() {
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let context = DiffPaneLSPContext(
            worktreeId: "worktree-1",
            worktreeRoot: URL(fileURLWithPath: "/tmp/worktree"),
            relativePath: "Sources/App/AlphaView.swift",
            language: "swift",
            lsp: manager,
            openTarget: { _, _, _ in }
        )
        let container = DiffPaneTextDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let group = try! #require(displayModel().groups.first)

        container.update(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "SF Mono", size: 13),
            theme: theme(),
            lspContext: context
        )
        container.layoutSubtreeIfNeeded()

        let splitTextViews = allSubviews(of: container).compactMap { $0 as? DiffPaneCodeTextView }
        #expect(splitTextViews.filter(\.hasLSPContextForTesting).count == 1)

        container.update(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "SF Mono", size: 13),
            theme: theme(),
            lspContext: context
        )
        container.layoutSubtreeIfNeeded()

        let stackedTextViews = allSubviews(of: container).compactMap { $0 as? DiffPaneCodeTextView }
        #expect(stackedTextViews.filter(\.hasLSPContextForTesting).count == 1)
    }

    @Test func placeholderSectionsRenderMessageWithoutDiffPane() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Assets/logo.png", status: .modified, isRenderable: false),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: "Binary files are not shown.",
            openFile: nil,
            contextProvider: nil
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewFileSection(
            file: file,
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsSourceBadge: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 900, height: 260)

        #expect(subview(withAccessibilityIdentifier: "diff-review-file-section-\(file.id.rawValue)", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "Binary files are not shown.") != nil)
        #expect(!allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
    }

    @Test func surfaceRepairsInvalidSelectedIDToFirstSessionFile() {
        let first = summary(path: "Sources/App/AlphaView.swift")
        let second = summary(path: "Tests/BetaTests.swift")
        let loaded = loadedSession(summaries: [first, second])
        var selected: DiffReviewFileID? = DiffReviewFileID(namespace: "commit", path: "Missing.swift")
        var collapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: loaded,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13
        )
        .environment(\.theme, theme())

        _ = host(view, width: 1000, height: 700)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        #expect(selected == first.id)
    }

    @Test func surfacePassesFeedbackToMatchingFileOnly() {
        let first = summary(path: "Sources/App.swift")
        let second = summary(path: "Sources/Other.swift")
        let session = loadedSession(summaries: [first, second])
        let feedback = [
            first.id: [
                DiffReviewInlineFeedback(
                    id: "thread-app",
                    providerName: "GitHub",
                    author: "reviewer",
                    bodyPreview: "App feedback.",
                    status: .actionable,
                    providerURL: nil,
                    anchor: DiffReviewInlineFeedbackAnchor(path: first.path, line: 2, side: .new),
                    evidenceItemID: "thread-app"
                ),
            ],
        ]
        var selected: DiffReviewFileID? = second.id
        var collapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selected }, set: { selected = $0 }),
            railCollapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            inlineFeedbackByFileID: feedback
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1000, height: 700)

        let matchingCards = allSubviews(of: controller.view).filter {
            $0.accessibilityIdentifier() == "diff-review-inline-feedback-thread-app"
        }
        #expect(matchingCards.count == 1)
        #expect(accessibilityLabel(in: controller.view, containing: "line 2") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "App feedback.") != nil)
    }

    @Test func surfaceShowsDraftSummaryRailAndSelectsDraftComment() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        let comment = draftComment(id: "draft-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        var selectedDraftID: String?

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            draftCommentsByFileID: [file.id: [comment]],
            onSelectDraftComment: { selectedDraftID = $0.id }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) != nil)
        let pressed = pressAccessibilityElement(
            withAccessibilityIdentifier: "review-draft-summary-comment-draft-summary",
            in: controller.view
        )

        #expect(pressed)
        #expect(selectedDraftID == "draft-summary")
    }

    @Test func surfaceCanShowDraftSummaryRailBeforeCommentsExist() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsDraftSummaryRail: true
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) != nil)
    }

    @Test func surfaceKeepsDraftSummaryRailWhenOnlyDismissedCommentsRemain() throws {
        let file = summary(path: "Sources/App.swift")
        let session = loadedSession(summaries: [file])
        let comment = draftComment(id: "draft-dismissed-only", fileID: file.id, path: file.path, side: .new, startLine: 2, state: .dismissed)
        var selectedFileID: DiffReviewFileID? = file.id
        var railCollapsed = false
        var summaryCollapsed = false
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false

        let view = DiffReviewSurface(
            session: session,
            selectedFileID: Binding(get: { selectedFileID }, set: { selectedFileID = $0 }),
            railCollapsed: Binding(get: { railCollapsed }, set: { railCollapsed = $0 }),
            reviewSummaryCollapsed: Binding(get: { summaryCollapsed }, set: { summaryCollapsed = $0 }),
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            draftCommentsByFileID: [file.id: [comment]]
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 1200, height: 700)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "dismissed") != nil)
    }

    @Test func summaryRailUsesProvidedBundleForCopyAndSendActions() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-bundle", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        let recorder = ReviewBundleActionRecorder()
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: true,
                    canShowSendToAgent: true,
                    canSendToAgent: true
                )
            },
            copyPrompt: { recorder.copied = $0 },
            agentTargets: { [.newChat(agentID: "codex", title: "Codex")] },
            sendToAgent: { bundle, target in
                recorder.sent = bundle
                recorder.sentTarget = target
            }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-copy-prompt", in: controller.view))
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-send-agent", in: controller.view))

        #expect(recorder.copied == bundle)
        #expect(recorder.sent == bundle)
        #expect(recorder.sentTarget == .newChat(agentID: "codex", title: "Codex"))
    }

    @Test func summaryRailCanPublishReview() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-publish-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review provider request",
                repositoryPath: "/repo",
                providerDescription: "GitHub #527",
                sourceDescription: "Provider review"
            ),
            comments: [comment]
        )
        var collapsed = false
        var didPublish = false
        let actions = ReviewDraftCommentActions(
            availability: { _ in .none },
            canPublishReview: { true },
            publishReview: { didPublish = true }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: controller.view))
        #expect(didPublish)
    }

    @Test func summaryRailHidesSendActionWhenNoAgentTargetExists() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-disabled-actions", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        let actions = ReviewDraftCommentActions(
            availability: { _ in .none },
            copyPrompt: { _ in Issue.record("disabled copy action fired") },
            agentTargets: { [] },
            sendToAgent: { _, _ in Issue.record("hidden send action fired") }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-copy-prompt", in: controller.view))
        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-send-agent", in: controller.view) == nil)
    }

    @Test func summaryRailCanDismissDraftComment() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-dismiss-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        var dismissedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: true,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            },
            dismiss: { dismissedID = $0.id }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "review-draft-summary-dismiss-draft-dismiss-summary",
            in: controller.view
        ))
        #expect(dismissedID == "draft-dismiss-summary")
    }

    @Test func summaryRailEditorDoesNotKeepCardSelectionPressActive() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-edit-summary", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false
        var selectedID: String?
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: true,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: false,
                    canShowSendToAgent: false,
                    canSendToAgent: false
                )
            }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { selectedID = $0.id }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)
        #expect(pressAccessibilityElement(
            withAccessibilityIdentifier: "review-draft-summary-edit-draft-edit-summary",
            in: controller.view
        ))
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-save-draft-edit-summary", in: controller.view) != nil)
        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-comment-draft-edit-summary", in: controller.view))
        #expect(selectedID == nil)
    }

    @Test func summaryRailShowsDismissedCommentsWithSideAndStatus() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(
            id: "draft-dismissed-visible",
            fileID: file.id,
            path: file.path,
            side: .old,
            startLine: 7,
            state: .dismissed
        )
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = false

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: ReviewDraftCommentActions(),
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 280, height: 500)

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-comment-draft-dismissed-visible", in: controller.view) != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "old line 7") != nil)
        #expect(accessibilityLabel(in: controller.view, containing: "dismissed") != nil)
    }

    @Test func collapsedSummaryRailKeepsFinishActionsAccessible() throws {
        let file = summary(path: "Sources/App.swift")
        let comment = draftComment(id: "draft-collapsed", fileID: file.id, path: file.path, side: .new, startLine: 2)
        let bundle = ReviewFeedbackBundle(
            target: ReviewFeedbackTarget(
                title: "Review Sources/App.swift",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local draft comments"
            ),
            comments: [comment]
        )
        var collapsed = true
        let recorder = ReviewBundleActionRecorder()
        let actions = ReviewDraftCommentActions(
            availability: { _ in
                ReviewDraftCommentActionAvailability(
                    canEdit: false,
                    canDelete: false,
                    canResolve: false,
                    canDismiss: false,
                    canCopyPrompt: true,
                    canShowSendToAgent: true,
                    canSendToAgent: true
                )
            },
            copyPrompt: { recorder.copied = $0 },
            agentTargets: { [.newChat(agentID: "codex", title: "Codex")] },
            sendToAgent: { bundle, target in
                recorder.sent = bundle
                recorder.sentTarget = target
            }
        )

        let view = ReviewDraftSummaryRail(
            comments: [comment],
            bundle: bundle,
            collapsed: Binding(get: { collapsed }, set: { collapsed = $0 }),
            draftCommentActions: actions,
            onSelectDraftComment: { _ in }
        )
        .environment(\.theme, theme())

        let controller = host(view, width: 80, height: 500)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-copy-prompt", in: controller.view))
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-send-agent", in: controller.view))

        #expect(recorder.copied == bundle)
        #expect(recorder.sent == bundle)
        #expect(recorder.sentTarget == .newChat(agentID: "codex", title: "Codex"))
    }

    @Test func selectionSynchronizationClearsEmptySessions() {
        let selected = DiffReviewFileID(namespace: "commit", path: "Stale.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: selected,
            fileIDs: []
        )

        #expect(result == nil)
    }

    @Test func selectionSynchronizationRepairsMissingSelection() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        let missing = DiffReviewFileID(namespace: "commit", path: "Missing.swift")

        let result = DiffReviewSurfaceSelectionSync.synchronizedSelection(
            current: missing,
            fileIDs: [first, second]
        )

        #expect(result == first)
    }

    @Test func sessionFileSetChangesResetProgrammaticScrollSuppression() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")
        var controller = DiffReviewProgrammaticScrollController()

        _ = controller.beginProgrammaticScroll(to: first)
        let result = DiffReviewSurfaceSelectionSync.synchronize(
            current: first,
            previousFileSetKey: "commit:First.swift",
            fileIDs: [second],
            programmaticScroll: controller
        )

        #expect(result.selectedFileID == second)
        #expect(result.fileSetKey == DiffReviewSurfaceSelectionSync.fileSetKey(for: [second]))
        #expect(!result.programmaticScroll.isSuppressing)
    }

    @Test func initialRestoredNonFirstSelectionRequestsScroll() {
        let first = DiffReviewFileID(namespace: "commit", path: "First.swift")
        let second = DiffReviewFileID(namespace: "commit", path: "Second.swift")

        #expect(
            DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
                previousFileSetKey: nil,
                previousSelection: second,
                selectedFileID: second,
                firstFileID: first
            )
        )
        #expect(
            !DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
                previousFileSetKey: nil,
                previousSelection: first,
                selectedFileID: first,
                firstFileID: first
            )
        )
        #expect(
            !DiffReviewSurfaceSelectionSync.shouldScrollRestoredSelection(
                previousFileSetKey: DiffReviewSurfaceSelectionSync.fileSetKey(for: [first, second]),
                previousSelection: second,
                selectedFileID: second,
                firstFileID: first
            )
        )
    }

    @Test func scrollCommandAdvancesGenerationForRepeatedFileSelections() {
        let file = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        var controller = DiffReviewScrollCommandController()

        let first = controller.command(to: file)
        let second = controller.command(to: file)

        #expect(first.id == file)
        #expect(second.id == file)
        #expect(second.generation == first.generation + 1)
    }

    @Test func scrollCommandConsumptionClearsOnlyConsumedCommand() {
        let file = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        let other = DiffReviewFileID(namespace: "commit", path: "Sources/Other.swift")
        var controller = DiffReviewScrollCommandController()

        let first = controller.command(to: file)
        let second = controller.command(to: other)

        #expect(
            DiffReviewScrollCommandConsumption.consume(
                current: first,
                consumed: first
            ) == nil
        )
        #expect(
            DiffReviewScrollCommandConsumption.consume(
                current: second,
                consumed: first
            ) == second
        )
    }

    @Test func renderWindowKeepsSelectedTargetAndNearViewportFiles() {
        let selected = DiffReviewFileID(namespace: "commit", path: "Selected.swift")
        let near = DiffReviewFileID(namespace: "commit", path: "Near.swift")
        let far = DiffReviewFileID(namespace: "commit", path: "Far.swift")
        let target = DiffReviewFileID(namespace: "commit", path: "Target.swift")
        let frames = [
            DiffReviewSectionFrame(id: near, minY: 520, maxY: 820),
            DiffReviewSectionFrame(id: far, minY: 5_000, maxY: 5_300),
        ]

        let rendered = DiffReviewRenderWindow.renderedFileIDs(
            current: [far],
            frames: frames,
            viewportHeight: 500,
            selectedFileID: selected,
            programmaticTarget: target,
            firstFileID: nil
        )

        #expect(rendered.contains(selected))
        #expect(rendered.contains(target))
        #expect(rendered.contains(near))
        #expect(!rendered.contains(far))
    }

    @Test func renderWindowRetainsRecentlyRenderedFilesNearViewport() {
        let visible = DiffReviewFileID(namespace: "commit", path: "Visible.swift")
        let justAbove = DiffReviewFileID(namespace: "commit", path: "JustAbove.swift")
        let justBelow = DiffReviewFileID(namespace: "commit", path: "JustBelow.swift")
        let far = DiffReviewFileID(namespace: "commit", path: "Far.swift")
        let frames = [
            DiffReviewSectionFrame(id: visible, minY: 120, maxY: 420),
            DiffReviewSectionFrame(id: justAbove, minY: -1_200, maxY: -900),
            DiffReviewSectionFrame(id: justBelow, minY: 1_600, maxY: 1_900),
            DiffReviewSectionFrame(id: far, minY: 9_000, maxY: 9_300),
        ]

        let rendered = DiffReviewRenderWindow.renderedFileIDs(
            current: [justAbove, justBelow, far],
            frames: frames,
            viewportHeight: 500,
            selectedFileID: nil,
            programmaticTarget: nil,
            firstFileID: nil
        )

        #expect(rendered.contains(visible))
        #expect(rendered.contains(justAbove))
        #expect(rendered.contains(justBelow))
        #expect(!rendered.contains(far))
    }

    @Test func estimatedSectionHeightScalesWithDiffRows() {
        let small = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/Small.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        var largeRows = Array(
            repeating: ParsedDiff.Hunk.Line(kind: .add, text: "let value = 1", oldNumber: nil, newNumber: 1),
            count: 40
        )
        largeRows.insert(.init(kind: .context, text: "let before = 0", oldNumber: 1, newNumber: 1), at: 0)
        let largeDiff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(header: "@@ -1,1 +1,41 @@", oldStart: 1, newStart: 1, lines: largeRows),
        ])
        let large = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/Large.swift", additions: 40),
            parsedDiff: largeDiff,
            displayModel: DiffDisplayModelBuilder.build(diff: largeDiff, filePath: "Sources/Large.swift"),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )

        #expect(DiffReviewFileSectionHeightEstimator.estimatedHeight(for: large) > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: small))
    }

    @Test func estimatedSectionHeightReservesBoundedInlineFeedbackHeight() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )

        let noFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 0)
        let oneFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 1)
        let cappedFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 4)
        let manyFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 10)

        #expect(oneFeedback > noFeedback)
        #expect(cappedFeedback > oneFeedback)
        #expect(manyFeedback == cappedFeedback)
    }

    @Test func estimatedSectionHeightGrowsWithInlineFeedbackBodyLength() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let shortFeedback = [
            DiffReviewInlineFeedback(
                id: "short",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Short.",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: nil, side: .unknown),
                evidenceItemID: "short"
            ),
        ]
        let longFeedback = [
            DiffReviewInlineFeedback(
                id: "long",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: Array(repeating: "This review comment needs to remain fully visible.", count: 12).joined(separator: " "),
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: file.summary.path, line: nil, side: .unknown),
                evidenceItemID: "long"
            ),
        ]

        #expect(
            DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: longFeedback)
                > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: shortFeedback)
        )
    }

    @Test func estimatedSectionHeightGrowsWithDraftComments() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(id: "draft-height", fileID: file.id, path: file.summary.path, side: .new, startLine: 2)

        #expect(
            DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [comment])
                > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [])
        )
    }

    @Test func estimatedSectionHeightGrowsWithDraftCommentsOnCollapsedRows() {
        let hiddenLine = diffLine(id: "hidden-new", side: .new, newLine: 12, text: "let hidden = true")
        let collapsedParent = DiffDisplayRow(
            id: "collapsed-parent",
            kind: .collapsed,
            old: nil,
            new: nil,
            collapsedLineCount: 1,
            collapsedRows: [
                DiffDisplayRow(
                    id: "hidden-row",
                    kind: .context,
                    old: nil,
                    new: hiddenLine,
                    collapsedLineCount: 0
                ),
            ]
        )
        let displayModel = DiffDisplayModel(
            filePath: "Sources/App.swift",
            groups: [
                DiffDisplayGroup(
                    id: "group",
                    header: "@@ -10,3 +10,3 @@",
                    sourceHunk: parsedDiff().hunks[0],
                    rows: [collapsedParent]
                ),
            ]
        )
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
        let comment = draftComment(
            id: "draft-collapsed-height",
            fileID: file.id,
            path: file.summary.path,
            side: .new,
            startLine: 12
        )

        #expect(
            DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [comment])
                > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedback: [], draftComments: [])
        )
    }

    @Test func inlineFeedbackCardEstimateUsesDynamicBodyHeight() {
        let short = DiffReviewInlineFeedback(
            id: "short",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Short.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
            evidenceItemID: "short"
        )
        let long = DiffReviewInlineFeedback(
            id: "long",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: Array(repeating: "Long feedback body.", count: 24).joined(separator: " "),
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/App.swift", line: nil, side: .unknown),
            evidenceItemID: "long"
        )

        #expect(DiffReviewInlineFeedbackDisplayPolicy.estimatedCardHeight(for: long) > DiffReviewInlineFeedbackDisplayPolicy.estimatedCardHeight(for: short))
        #expect(DiffReviewInlineFeedbackDisplayPolicy.estimatedCardHeight(for: short) >= DiffReviewInlineFeedbackDisplayPolicy.cardMinimumHeight)
    }

    private func parsedDiff() -> ParsedDiff {
        ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,2 +1,2 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
                    .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                    .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
                ]
            ),
        ])
    }

    private func displayModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App/AlphaView.swift")
    }

    private func loadedSession(summaries: [DiffReviewFileSummary]) -> DiffReviewLoadedSession {
        DiffReviewLoadedSession(
            files: summaries.map { summary in
                DiffReviewFileSectionModel(
                    summary: summary,
                    parsedDiff: nil,
                    displayModel: nil,
                    placeholderMessage: "No diff.",
                    openFile: nil,
                    contextProvider: nil
                )
            },
            summary: DiffReviewSessionModel(files: summaries, groupsEnabled: false)
        )
    }

    private func inlineFeedbackItems(
        count: Int,
        path: String,
        lineAnchored: Bool = true
    ) -> [DiffReviewInlineFeedback] {
        (1...count).map { index in
            DiffReviewInlineFeedback(
                id: "thread-\(index)",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Feedback \(index).",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(
                    path: path,
                    line: lineAnchored ? index : nil,
                    side: lineAnchored ? .new : .unknown
                ),
                evidenceItemID: "thread-\(index)"
            )
        }
    }

    private func draftComment(
        id: String,
        fileID: DiffReviewFileID = DiffReviewFileID(namespace: "commit", path: "A.swift"),
        path: String = "A.swift",
        side: DiffReviewInlineFeedbackSide = .new,
        startLine: Int,
        endLine: Int? = nil,
        state: ReviewDraftCommentState = .active
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .commit(
                worktreeID: "wt",
                repositoryPath: URL(fileURLWithPath: "/repo"),
                sha: "abc123"
            ),
            fileID: fileID,
            path: path,
            originalPath: nil,
            side: side,
            startLine: startLine,
            endLine: endLine,
            selectedText: "let b = 3",
            bodyMarkdown: "Please revisit this line.",
            state: state,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private func diffLine(
        id: String,
        side: DiffLineSide,
        oldLine: Int? = nil,
        newLine: Int? = nil,
        text: String
    ) -> DiffDisplayLine {
        DiffDisplayLine(
            id: id,
            anchor: DiffLineAnchor(
                filePath: "A.swift",
                hunkIndex: 0,
                rowIndex: 0,
                side: side,
                oldLine: oldLine,
                newLine: newLine
            ),
            text: text,
            lineNumber: oldLine ?? newLine,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )
    }

    private func summary(
        path: String,
        namespace: String = "commit",
        groupID: String? = nil,
        groupTitle: String? = nil,
        status: DiffReviewFileStatus = .modified,
        additions: Int = 1,
        deletions: Int = 0,
        isRenderable: Bool = true,
        originalPath: String? = nil
    ) -> DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: path,
            namespace: namespace,
            groupID: groupID,
            groupTitle: groupTitle,
            status: status,
            additions: additions,
            deletions: deletions,
            isRenderable: isRenderable,
            originalPath: originalPath
        )
    }

    private func host<Content: View>(
        _ view: Content,
        width: CGFloat,
        height: CGFloat
    ) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }

    private func subviews(withAccessibilityIdentifier identifier: String, in view: NSView) -> [NSView] {
        var matches: [NSView] = []
        if view.accessibilityIdentifier() == identifier {
            matches.append(view)
        }
        matches.append(contentsOf: view.subviews.flatMap { subviews(withAccessibilityIdentifier: identifier, in: $0) })
        return matches
    }

    private func pressAccessibilityElement(withAccessibilityIdentifier identifier: String, in view: NSView) -> Bool {
        for match in subviews(withAccessibilityIdentifier: identifier, in: view) {
            if match.accessibilityPerformPress() {
                return true
            }
        }
        return false
    }

    private func accessibilityLabel(in view: NSView, containing text: String) -> String? {
        if let label = view.accessibilityLabel(), label.contains(text) {
            return label
        }
        return view.subviews.lazy.compactMap { accessibilityLabel(in: $0, containing: text) }.first
    }
}

private final class ReviewBundleActionRecorder: @unchecked Sendable {
    var copied: ReviewFeedbackBundle?
    var sent: ReviewFeedbackBundle?
    var sentTarget: ReviewFeedbackAgentTarget?
}
