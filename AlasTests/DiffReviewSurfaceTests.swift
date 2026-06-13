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
            openFile: {}
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
            openFile: nil
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
            openFile: nil
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

    @Test func fileSectionCapsInlineFeedbackCardsWithMoreRow() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil
        )
        let feedback = inlineFeedbackItems(count: 5, path: file.summary.path)
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
            openFile: nil
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

    @Test func scrollCommandAdvancesGenerationForRepeatedFileSelections() {
        let file = DiffReviewFileID(namespace: "commit", path: "Sources/App.swift")
        var controller = DiffReviewScrollCommandController()

        let first = controller.command(to: file)
        let second = controller.command(to: file)

        #expect(first.id == file)
        #expect(second.id == file)
        #expect(second.generation == first.generation + 1)
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

    @Test func estimatedSectionHeightScalesWithDiffRows() {
        let small = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/Small.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil
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
            openFile: nil
        )

        #expect(DiffReviewFileSectionHeightEstimator.estimatedHeight(for: large) > DiffReviewFileSectionHeightEstimator.estimatedHeight(for: small))
    }

    @Test func estimatedSectionHeightReservesBoundedInlineFeedbackHeight() {
        let file = DiffReviewFileSectionModel(
            summary: summary(path: "Sources/App.swift"),
            parsedDiff: parsedDiff(),
            displayModel: displayModel(),
            placeholderMessage: nil,
            openFile: nil
        )

        let noFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 0)
        let oneFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 1)
        let cappedFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 4)
        let manyFeedback = DiffReviewFileSectionHeightEstimator.estimatedHeight(for: file, inlineFeedbackCount: 10)

        #expect(oneFeedback > noFeedback)
        #expect(cappedFeedback > oneFeedback)
        #expect(manyFeedback == cappedFeedback)
    }

    @Test func inlineFeedbackCardEstimateReservesThreeLinePreviewHeight() {
        #expect(DiffReviewInlineFeedbackDisplayPolicy.cardEstimatedHeight >= 78)
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
                    openFile: nil
                )
            },
            summary: DiffReviewSessionModel(files: summaries, groupsEnabled: false)
        )
    }

    private func inlineFeedbackItems(count: Int, path: String) -> [DiffReviewInlineFeedback] {
        (1...count).map { index in
            DiffReviewInlineFeedback(
                id: "thread-\(index)",
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "Feedback \(index).",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: path, line: index, side: .new),
                evidenceItemID: "thread-\(index)"
            )
        }
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

    private func accessibilityLabel(in view: NSView, containing text: String) -> String? {
        if let label = view.accessibilityLabel(), label.contains(text) {
            return label
        }
        return view.subviews.lazy.compactMap { accessibilityLabel(in: $0, containing: text) }.first
    }
}
