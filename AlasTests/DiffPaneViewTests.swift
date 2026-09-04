import AppKit
import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffPaneViewTests {
    private func theme() -> Theme { try! ThemeStore().current }

    @Test func splitRowHeightSyncConvergesForUnicodeFallbackGlyph() throws {
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = #"        printProgress("  ⟳ Pressing $label...")"#
        let line = DiffDisplayLine(
            id: "ScoutOrchestrator.kt:new:344",
            anchor: DiffLineAnchor(
                filePath: "ScoutOrchestrator.kt",
                hunkIndex: 0,
                rowIndex: 0,
                side: .new,
                oldLine: nil,
                newLine: 344
            ),
            text: text,
            lineNumber: 344,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let row = DiffDisplayRow(
            id: "ScoutOrchestrator.kt:344",
            kind: .add,
            old: nil,
            new: line,
            collapsedLineCount: 0
        )
        let container = DiffPaneTextDocumentContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 1))
        container.update(
            rows: [row],
            layoutMode: .split,
            wrapLines: true,
            showWhitespace: false,
            fileExtension: "kt",
            font: font,
            theme: theme(),
            lspContext: nil
        )

        let initialHeight = container.intrinsicContentSize.height
        for _ in 0..<20 {
            container.layout()
        }

        #expect(container.intrinsicContentSize.height <= initialHeight + 1)
    }

    @Test func diffRowRectsReturnOnlyIndicesIntersectingDirtyVerticalRange() {
        let rows = [
            NSRect(x: 0, y: 0, width: 100, height: 10),
            NSRect(x: 0, y: 10, width: 100, height: 10),
            NSRect(x: 0, y: 20, width: 100, height: 10),
            NSRect(x: 0, y: 30, width: 100, height: 10),
        ]

        #expect(rows.indicesIntersecting(NSRect(x: 0, y: 10, width: 100, height: 10)) == 1..<2)
        #expect(rows.indicesIntersecting(NSRect(x: 0, y: 9, width: 100, height: 12)) == 0..<3)
        #expect(rows.indicesIntersecting(NSRect(x: 0, y: 40, width: 100, height: 10)).isEmpty)
        #expect([NSRect]().indicesIntersecting(.zero).isEmpty)
    }

    private func model() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: parsedDiff(),
            filePath: "a.swift"
        )
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
                )
            ]
        )
    }

    private func reviewAnchorModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,2 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
                        .init(kind: .delete, text: "let b = 2", oldNumber: 2, newNumber: nil),
                        .init(kind: .add, text: "let b = 3", oldNumber: nil, newNumber: 2),
                    ]
                )
            ]),
            filePath: "Sources/App.swift"
        )
    }

    private func collapsedContextModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,15 +1,15 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: (1...15).map {
                        .init(kind: .context, text: "let value\($0) = \($0)", oldNumber: $0, newNumber: $0)
                    }
                )
            ]),
            filePath: "a.swift"
        )
    }

    private func expandableContextGroup(
        boundary: DiffContextBoundary,
        collapsedLineCount: Int
    ) -> DiffDisplayGroup {
        let groupID = "hunk-0"
        return DiffDisplayGroup(
            id: groupID,
            header: "@@ -2,1 +2,1 @@",
            sourceHunk: ParsedDiff.Hunk(
                header: "@@ -2,1 +2,1 @@",
                oldStart: 2,
                newStart: 2,
                lines: []
            ),
            rows: [
                DiffDisplayRow(
                    id: "expand-\(boundary.rawValue)",
                    kind: .expandableContext,
                    old: nil,
                    new: nil,
                    collapsedLineCount: collapsedLineCount,
                    contextExpansion: DiffContextExpansionRow(
                        key: DiffContextExpansionKey(groupID: groupID, boundary: boundary),
                        boundary: boundary,
                        remainingLineCount: collapsedLineCount
                    )
                ),
            ]
        )
    }

    private func sharedExpandableContextGroup(
        edge: DiffContextExpansionEdge?,
        collapsedLineCount: Int
    ) -> DiffDisplayGroup {
        let upperGroupID = "hunk-0"
        let lowerGroupID = "hunk-1"
        let boundary: DiffContextBoundary = edge == .bottom ? .above : .below
        return DiffDisplayGroup(
            id: edge == .bottom ? lowerGroupID : upperGroupID,
            header: "@@ -2,1 +2,1 @@",
            sourceHunk: ParsedDiff.Hunk(
                header: "@@ -2,1 +2,1 @@",
                oldStart: 2,
                newStart: 2,
                lines: []
            ),
            rows: [
                DiffDisplayRow(
                    id: "shared-expand-\(edge?.rawValue ?? "all")",
                    kind: .expandableContext,
                    old: nil,
                    new: nil,
                    collapsedLineCount: collapsedLineCount,
                    contextExpansion: DiffContextExpansionRow(
                        key: .shared(upperGroupID: upperGroupID, lowerGroupID: lowerGroupID),
                        boundary: boundary,
                        remainingLineCount: collapsedLineCount,
                        edge: edge,
                        defaultsEdgeFromBoundary: edge != nil
                    )
                ),
            ]
        )
    }

    private func diffLine(id: String, side: DiffLineSide, oldLine: Int? = nil, newLine: Int? = nil, text: String) -> DiffDisplayLine {
        DiffDisplayLine(
            id: id,
            anchor: DiffLineAnchor(
                filePath: "Sources/App.swift",
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

    private final class WriteRecorder {
        var writeCount = 0
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        let recorder: WriteRecorder?

        init(recorder: WriteRecorder? = nil) {
            self.recorder = recorder
        }

        func write<T: Encodable>(_: T, to _: URL) throws {
            recorder?.writeCount += 1
        }
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private func reviewGroup(
        _ displayGroup: DiffDisplayGroup,
        inlineFeedback: [DiffReviewInlineFeedback] = []
    ) -> DiffReviewRenderContext.Group {
        DiffReviewRenderContext.Group(
            displayGroup: displayGroup,
            inlineFeedback: inlineFeedback,
            segments: [
                DiffReviewRenderContext.Segment(
                    id: "\(displayGroup.id)-segment",
                    rows: displayGroup.rows,
                    draftComments: [],
                    showsComposer: false,
                    blocks: []
                ),
            ]
        )
    }

    private func inlineFeedback(path: String = "a.swift", line: Int = 1) -> DiffReviewInlineFeedback {
        DiffReviewInlineFeedback(
            id: "feedback-\(line)",
            providerName: "GitHub",
            author: "reviewer",
            bodyPreview: "Review this.",
            status: .actionable,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: path, line: line, side: .new),
            evidenceItemID: "feedback-\(line)"
        )
    }

    @Test func hunkFusionResolverDoesNotFuseHiddenSharedBridgeRows() throws {
        let upper = sharedExpandableContextGroup(edge: .top, collapsedLineCount: 8)
        let lower = sharedExpandableContextGroup(edge: .bottom, collapsedLineCount: 8)

        let states = DiffPaneHunkFusionResolver.states(for: [upper, lower])

        #expect(states == [.none, .none])
    }

    @Test func hunkFusionResolverFusesFullyExpandedSharedBoundaryWithoutBridgeRows() throws {
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let upper = DiffDisplayGroup(
            id: "hunk-0",
            header: "@@ -2,1 +2,1 @@",
            sourceHunk: ParsedDiff.Hunk(
                header: "@@ -2,1 +2,1 @@",
                oldStart: 2,
                newStart: 2,
                lines: []
            ),
            rows: [],
            sharedContextAfter: key
        )
        let lower = DiffDisplayGroup(
            id: "hunk-1",
            header: "@@ -4,1 +4,1 @@",
            sourceHunk: ParsedDiff.Hunk(
                header: "@@ -4,1 +4,1 @@",
                oldStart: 4,
                newStart: 4,
                lines: []
            ),
            rows: [],
            sharedContextBefore: key
        )

        let states = DiffPaneHunkFusionResolver.states(for: [upper, lower])

        #expect(states[0] == DiffPaneHunkFusionState(fusedWithPrevious: false, fusedWithNext: true))
        #expect(states[1] == DiffPaneHunkFusionState(fusedWithPrevious: true, fusedWithNext: false))
    }

    @Test func hunkFusionResolverDoesNotFuseDifferentSharedBridgeKeys() throws {
        let upper = sharedExpandableContextGroup(edge: .top, collapsedLineCount: 8)
        let lower = DiffDisplayGroup(
            id: "hunk-2",
            header: "@@ -20,1 +20,1 @@",
            sourceHunk: ParsedDiff.Hunk(
                header: "@@ -20,1 +20,1 @@",
                oldStart: 20,
                newStart: 20,
                lines: []
            ),
            rows: [
                DiffDisplayRow(
                    id: "shared-expand-bottom-other",
                    kind: .expandableContext,
                    old: nil,
                    new: nil,
                    collapsedLineCount: 8,
                    contextExpansion: DiffContextExpansionRow(
                        key: .shared(upperGroupID: "hunk-1", lowerGroupID: "hunk-2"),
                        boundary: .above,
                        remainingLineCount: 8,
                        edge: .bottom
                    )
                ),
            ]
        )

        let states = DiffPaneHunkFusionResolver.states(for: [upper, lower])

        #expect(states == [.none, .none])
    }

    @Test func hunkFusionResolverDoesNotFuseWhenOnlyOneSideHasSharedBridge() throws {
        let upper = sharedExpandableContextGroup(edge: .top, collapsedLineCount: 8)
        let lower = expandableContextGroup(boundary: .above, collapsedLineCount: 8)

        let states = DiffPaneHunkFusionResolver.states(for: [upper, lower])

        #expect(states == [.none, .none])
    }

    @Test func hunkFusionStateBottomPaddingIsZeroOnlyWhenFusedWithNext() {
        #expect(DiffPaneHunkFusionState.none.bottomPadding == 10)
        #expect(DiffPaneHunkFusionState(fusedWithPrevious: false, fusedWithNext: true).bottomPadding == 0)
        #expect(DiffPaneHunkFusionState(fusedWithPrevious: true, fusedWithNext: false).bottomPadding == 10)
    }

    @Test func hunkFusionStateOuterPaddingIsZeroAtFusedEdges() {
        #expect(DiffPaneHunkFusionState.none.outerTopPadding == 10)
        #expect(DiffPaneHunkFusionState.none.outerBottomPadding == 10)
        #expect(DiffPaneHunkFusionState(fusedWithPrevious: true, fusedWithNext: false).outerTopPadding == 0)
        #expect(DiffPaneHunkFusionState(fusedWithPrevious: false, fusedWithNext: true).outerBottomPadding == 0)
    }

    @Test func reviewHunkFusionResolverDoesNotFuseAcrossLowerInlineFeedback() throws {
        let upper = sharedExpandableContextGroup(edge: .top, collapsedLineCount: 8)
        let lower = sharedExpandableContextGroup(edge: .bottom, collapsedLineCount: 8)

        let states = DiffReviewHunkFusionResolver.states(for: [
            reviewGroup(upper),
            reviewGroup(lower, inlineFeedback: [inlineFeedback(line: 2)]),
        ])

        #expect(states == [.none, .none])
    }

    @Test func diffTabRenderContextMatchesDraftPlacementAndSegmentationHelpers() throws {
        let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
        let group = try #require(model.groups.first)
        let fileID = DiffReviewFileID(namespace: "diff-tab", path: "Sources/App.swift")
        let comment = ReviewDraftComment(
            id: "draft-tab",
            sessionID: .localChanges(
                worktreeID: "worktree",
                worktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                scope: .unstaged
            ),
            fileID: fileID,
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 2,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Draft body",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let context = DiffTabRenderContextBuilder.build(
            model: model,
            comments: [comment],
            pendingDraftAnchor: nil
        )

        let expectedPlacement = ReviewDraftCommentPlacement.position([comment], in: model.groups)
        let expectedSegments = ReviewDraftCommentRowSegmentation.segments(
            for: group,
            placement: expectedPlacement,
            pendingAnchor: nil
        )

        #expect(context.fileLevelDraftComments == expectedPlacement.fileLevel)
        #expect(context.draftPlacement == expectedPlacement)
        #expect(context.group(id: group.id)?.segments == expectedSegments.items)
    }

    @Test func diffTabDraftAccessoriesResolveSemanticLanesAndSegmentGeometry() throws {
        let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
        let group = try #require(model.groups.first)
        let fileID = DiffReviewFileID(namespace: "diff-tab", path: "Sources/App.swift")
        let comment = reviewDraftComment(id: "draft-new-lane", fileID: fileID)
        let pendingAnchor = DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: .old,
            line: 2,
            rowIndex: 1,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .old, line: 2, isChange: true),
            ],
            selectedText: "let b = 2"
        )
        let context = DiffTabRenderContextBuilder.build(
            model: model,
            comments: [comment],
            pendingDraftAnchor: pendingAnchor
        )
        let segment = try #require(context.group(id: group.id)?.segments.first {
            !$0.draftComments.isEmpty || $0.showsComposer
        })

        #expect(DiffFeedbackLaneResolver.lane(for: comment) == .right)
        #expect(DiffFeedbackLaneResolver.lane(for: pendingAnchor) == .left)
        #expect(segment.rows.isEmpty == false)

        let splitFrame = DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: 900,
            layoutMode: .split,
            lane: .left,
            gutterWidth: 42
        )
        let stackedFrame = DiffFeedbackLaneGeometry.contentFrame(
            containerWidth: 900,
            layoutMode: .stacked,
            lane: .left,
            gutterWidth: 42
        )
        #expect(splitFrame.width == 407)
        #expect(stackedFrame.width == 858)
    }

    @Test func pendingDraftComposerLaneUsesAnchorResolverInSplitAndStackedLayouts() throws {
        let rows = try #require(model().groups.first?.rows)
        let pendingAnchor = DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: .old,
            line: 2,
            rowIndex: 1,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .old, line: 2, isChange: true),
            ],
            selectedText: "let b = 2"
        )
        let splitController = NSHostingController(rootView:
            DiffFeedbackLaneView(
                lane: DiffFeedbackLaneResolver.lane(for: pendingAnchor),
                layoutMode: .split,
                rows: rows
            ) {
                FrameProbe(identifier: "diff-review-draft-composer")
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
            .environment(\.theme, theme())
        )
        splitController.view.frame = NSRect(x: 0, y: 0, width: 900, height: 80)
        splitController.view.layoutSubtreeIfNeeded()

        #expect(subview(
            withAccessibilityIdentifier: "diff-feedback-lane-left",
            in: splitController.view
        ) != nil)
        #expect(subview(
            withAccessibilityIdentifier: "diff-review-draft-composer",
            in: splitController.view
        ) != nil)

        let stackedController = NSHostingController(rootView:
            DiffFeedbackLaneView(
                lane: DiffFeedbackLaneResolver.lane(for: pendingAnchor),
                layoutMode: .stacked,
                rows: rows
            ) {
                FrameProbe(identifier: "diff-review-draft-composer")
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
            }
            .environment(\.theme, theme())
        )
        stackedController.view.frame = NSRect(x: 0, y: 0, width: 900, height: 80)
        stackedController.view.layoutSubtreeIfNeeded()

        #expect(subview(
            withAccessibilityIdentifier: "diff-feedback-lane-full",
            in: stackedController.view
        ) != nil)
    }

    @MainActor
    @Test func diffTabRenderContextCacheReusesMatchingKeyAndEvictsPastLimit() throws {
        let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
        let cache = DiffTabRenderContextCache(limit: 2)
        let key = DiffTabRenderContextKey(
            model: model,
            comments: [],
            pendingDraftAnchor: nil
        )
        let comment = reviewDraftComment(id: "draft-cache", fileID: DiffReviewFileID(namespace: "diff-tab", path: "Sources/App.swift"))
        let commentKey = DiffTabRenderContextKey(
            model: model,
            comments: [comment],
            pendingDraftAnchor: nil
        )
        let pendingKey = DiffTabRenderContextKey(
            model: model,
            comments: [],
            pendingDraftAnchor: DiffReviewLineAnchor(
                path: "Sources/App.swift",
                side: .new,
                line: 2,
                rowIndex: 2,
                selectedText: "let b = 3"
            )
        )
        var buildCount = 0

        _ = cache.context(key: key) {
            buildCount += 1
            return DiffTabRenderContextBuilder.build(model: model, comments: [], pendingDraftAnchor: nil)
        }
        _ = cache.context(key: key) {
            buildCount += 1
            return DiffTabRenderContextBuilder.build(model: model, comments: [], pendingDraftAnchor: nil)
        }

        #expect(buildCount == 1)

        _ = cache.context(key: commentKey) {
            buildCount += 1
            return DiffTabRenderContextBuilder.build(model: model, comments: [comment], pendingDraftAnchor: nil)
        }
        _ = cache.context(key: pendingKey) {
            buildCount += 1
            return DiffTabRenderContextBuilder.build(model: model, comments: [], pendingDraftAnchor: nil)
        }
        _ = cache.context(key: key) {
            buildCount += 1
            return DiffTabRenderContextBuilder.build(model: model, comments: [], pendingDraftAnchor: nil)
        }

        #expect(buildCount == 4)
    }

    @Test func diffTabRenderContextKeyIgnoresPresentationInputs() {
        let model = DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
        let fileID = DiffReviewFileID(namespace: "diff-tab", path: "Sources/App.swift")
        let comment = reviewDraftComment(id: "draft-key", fileID: fileID)
        let pendingAnchor = DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: .new,
            line: 2,
            rowIndex: 2,
            selectedText: "let b = 3"
        )
        let baseKey = DiffTabRenderContextKey(model: model, comments: [], pendingDraftAnchor: nil)
        let equalKey = DiffTabRenderContextKey(model: model, comments: [], pendingDraftAnchor: nil)
        let commentKey = DiffTabRenderContextKey(model: model, comments: [comment], pendingDraftAnchor: nil)
        let pendingKey = DiffTabRenderContextKey(model: model, comments: [], pendingDraftAnchor: pendingAnchor)

        #expect(baseKey == equalKey)
        #expect(baseKey != commentKey)
        #expect(baseKey != pendingKey)
    }

    @MainActor
    @Test func diffTabViewRenderContextCacheIgnoresPresentationPreferenceChanges() async throws {
        let repo = try makeTemporaryDiffRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState(store: MemoryStore())
        state.config.changes.diffLayoutMode = .split
        var missCount = 0
        var view = DiffTabView(
            worktreePath: repo,
            relativePath: "Sources/App.swift",
            staged: false,
            originalPath: nil,
            compareWithHEAD: false,
            worktreeId: "worktree",
            appState: state,
            onOpenFile: nil,
            onRequestDiscardFile: nil
        )
        #if DEBUG
        view.onRenderContextCacheMissForTesting = { missCount += 1 }
        #endif
        let controller = NSHostingController(rootView: view.environment(\.theme, theme()))
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)

        try await waitForRenderPass(controller: controller) { missCount == 1 }
        #expect(visibleCodeTextViews(in: controller.view).count == 2)

        state.config.changes.diffLayoutMode = .stacked
        try await waitForRenderPass(controller: controller) {
            visibleCodeTextViews(in: controller.view).count == 1
        }

        #expect(missCount == 1)
    }

    @MainActor
    @Test func diffTabViewRefocusesDraftComposerAfterSelectingDifferentGutterRows() async throws {
        let repo = try makeTemporaryDiffRepository()
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState(store: MemoryStore())
        state.config.changes.diffLayoutMode = .stacked
        let view = DiffTabView(
            worktreePath: repo,
            relativePath: "Sources/App.swift",
            staged: false,
            originalPath: nil,
            compareWithHEAD: false,
            worktreeId: "worktree",
            appState: state,
            onOpenFile: nil,
            onRequestDiscardFile: nil
        )
        .environment(\.theme, theme())
        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 520)
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        defer { DiffTabViewFocusRetainer.retain(window, controller) }

        try await waitForRenderPass(controller: controller) {
            !visibleReviewRulers(in: controller.view).isEmpty
        }
        try selectReviewLine(selectionIndex: 0, in: controller.view)
        try await waitForRenderPass(controller: controller) {
            draftComposerTextView(in: controller.view).map { window.firstResponder === $0 } ?? false
        }

        let firstComposer = try #require(draftComposerTextView(in: controller.view))
        let sink = DiffTabViewFocusSinkView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        controller.view.addSubview(sink)
        #expect(window.makeFirstResponder(sink))
        #expect(window.firstResponder !== firstComposer)

        try selectReviewLine(selectionIndex: 1, in: controller.view)
        try await waitForRenderPass(controller: controller) {
            draftComposerTextView(in: controller.view).map { window.firstResponder === $0 } ?? false
        }

        let relocatedComposer = try #require(draftComposerTextView(in: controller.view))
        #expect(window.firstResponder === relocatedComposer)
    }

    @Test func splitModeHostsRendererWithoutCrashing() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.subviews.isEmpty == false)
    }

    @Test func stackedModeHostsRendererWithoutCrashing() {
        var layout = DiffLayoutMode.stacked
        var wrap = true
        var whitespace = true
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        #expect(controller.view.subviews.isEmpty == false)
    }

    @Test func providerAccessoriesUseSemanticLanesAndStackedFullWidth() throws {
        let thread = DiffInlineCommentThread(
            id: "thread-old",
            filePath: "a.swift",
            newLine: 2,
            isOldSide: true,
            isResolved: false,
            isOutdated: false,
            comments: [
                DiffInlineComment(id: "comment-old", author: "reviewer", body: "Old-side feedback"),
            ]
        )
        let annotation = DiffInlineAnnotation(
            id: "annotation-new",
            checkName: "SwiftLint",
            newLine: 2,
            level: .warning,
            message: "New-side annotation",
            rawDetails: nil
        )
        var splitLayout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let splitView = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { splitLayout }, set: { splitLayout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            threads: [thread],
            annotations: [annotation],
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let splitController = NSHostingController(rootView: splitView)
        splitController.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        splitController.view.layoutSubtreeIfNeeded()

        #expect(subview(
            withAccessibilityIdentifier: "diff-feedback-lane-left",
            in: splitController.view
        ) != nil)
        #expect(subview(
            withAccessibilityIdentifier: "diff-feedback-lane-right",
            in: splitController.view
        ) != nil)

        var stackedLayout = DiffLayoutMode.stacked
        let stackedView = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { stackedLayout }, set: { stackedLayout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            threads: [thread],
            annotations: [annotation],
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let stackedController = NSHostingController(rootView: stackedView)
        stackedController.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        stackedController.view.layoutSubtreeIfNeeded()

        let fullLaneMarkers = allSubviews(of: stackedController.view).filter {
            $0.accessibilityIdentifier() == "diff-feedback-lane-full"
        }
        #expect(fullLaneMarkers.count == 2)
    }

    @Test func defaultModeShowsDiffToolbar() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) != nil)
    }

    @Test func embeddedModeHidesDiffToolbar() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-pane-toolbar", in: controller.view) == nil)
    }

    @Test func embeddedStaticModeDoesNotCreateOuterVerticalScrollView() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let outerScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? NSScrollView }
            .filter { !($0 is DiffPaneTextScrollView) }
        #expect(outerScrollViews.isEmpty)
        #expect(allSubviews(of: controller.view).contains { $0 is DiffPaneTextScrollView })
    }

    @Test func stackedStaticModeBoundsSegmentMaterializationToScrollViewport() throws {
        let baseGroup = try #require(model().groups.first)
        let groups = (0..<80).map { index in
            DiffDisplayGroup(
                id: "group-\(index)",
                header: "@@ -\(index + 1),2 +\(index + 1),2 @@",
                sourceHunk: baseGroup.sourceHunk,
                rows: baseGroup.rows
            )
        }
        var layout = DiffLayoutMode.stacked
        var wrap = false
        var whitespace = false
        let pane = DiffPaneView(
            model: DiffDisplayModel(filePath: "large.swift", groups: groups),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: ScrollView(.vertical) { pane })
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
        }

        let materializedSegments = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
        let initialIdentities = Set(materializedSegments.map(ObjectIdentifier.init))
        #expect(!materializedSegments.isEmpty)
        #expect(materializedSegments.count < groups.count)

        for _ in 0..<10 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
        }

        let settledIdentities = Set(allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
            .map(ObjectIdentifier.init))
        #expect(settledIdentities == initialIdentities)
    }

    @Test func staticModeEstimatedHeightScalesWithRenderedRows() throws {
        let baseGroup = try #require(model().groups.first)
        let groups = (0..<12).map { index in
            DiffDisplayGroup(
                id: "group-\(index)",
                header: "@@ -\(index + 1),2 +\(index + 1),2 @@",
                sourceHunk: baseGroup.sourceHunk,
                rows: baseGroup.rows
            )
        }
        let smallModel = DiffDisplayModel(filePath: "small.swift", groups: [baseGroup])
        let largeModel = DiffDisplayModel(filePath: "large.swift", groups: groups)
        let unwrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: largeModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: []
        )

        #expect(unwrappedHeight > DiffPaneStaticHeightEstimator.estimatedHeight(
            for: smallModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: []
        ))

        let smallFontHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: largeModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            codeFont: .monospacedSystemFont(ofSize: 8, weight: .regular)
        )
        let largeFontHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: largeModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            codeFont: .monospacedSystemFont(ofSize: 16, weight: .regular)
        )
        #expect(smallFontHeight < largeFontHeight)

        let fusedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: largeModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            fusionStates: groups.map { _ in DiffPaneHunkFusionState(fusedWithPrevious: true, fusedWithNext: true) },
        )
        #expect(fusedHeight < unwrappedHeight)

        let longLine = String(repeating: "let wrappedValue = computeSomethingExpensive() ", count: 10)
        let wrappedModel = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,1 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .delete, text: longLine, oldNumber: 1, newNumber: nil),
                        .init(kind: .add, text: longLine, oldNumber: nil, newNumber: 1),
                    ]
                )
            ]),
            filePath: "Wrapped.swift"
        )
        let narrowWrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: wrappedModel,
            layoutMode: .split,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 320
        )
        let wideWrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: wrappedModel,
            layoutMode: .split,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 1_200
        )
        let noWrapHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: wrappedModel,
            layoutMode: .split,
            expandedCollapsedRowIDs: [],
            wrapLines: false,
            availableWidth: 320
        )
        #expect(narrowWrappedHeight > wideWrappedHeight)
        #expect(narrowWrappedHeight > noWrapHeight)

        let tabbedModel = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,1 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: String(repeating: "\tvalue", count: 16), oldNumber: 1, newNumber: 1),
                    ]
                ),
            ]),
            filePath: "Tabbed.swift"
        )
        let spacesModel = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,1 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: String(repeating: " value", count: 16), oldNumber: 1, newNumber: 1),
                    ]
                ),
            ]),
            filePath: "Spaces.swift"
        )
        let tabbedWrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: tabbedModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 180
        )
        let spacesWrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: spacesModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 180
        )
        #expect(tabbedWrappedHeight > spacesWrappedHeight)
        #expect(DiffPaneStaticHeightEstimator.estimatedHeight(
            for: tabbedModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 180,
            showWhitespace: true
        ) < tabbedWrappedHeight)

        let smallLineNumberModel = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,1 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .context, text: String(repeating: "value ", count: 20), oldNumber: 1, newNumber: 1),
                    ]
                ),
            ]),
            filePath: "SmallLineNumber.swift"
        )
        let largeLineNumberModel = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1000000000,1 +1000000000,1 @@",
                    oldStart: 1_000_000_000,
                    newStart: 1_000_000_000,
                    lines: [
                        .init(
                            kind: .context,
                            text: String(repeating: "value ", count: 20),
                            oldNumber: 1_000_000_000,
                            newNumber: 1_000_000_000
                        ),
                    ]
                ),
            ]),
            filePath: "LargeLineNumber.swift"
        )
        let smallLineNumberHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: smallLineNumberModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 100
        )
        let largeLineNumberHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: largeLineNumberModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 100
        )
        #expect(largeLineNumberHeight > smallLineNumberHeight)

        let collapsedModel = DiffDisplayModel(filePath: "Collapsed.swift", groups: [
            DiffDisplayGroup(
                id: "collapsed",
                header: "@@ -1,1 +1,1 @@",
                sourceHunk: baseGroup.sourceHunk,
                rows: [
                    DiffDisplayRow(
                        id: "collapsed-row",
                        kind: .collapsed,
                        old: nil,
                        new: nil,
                        collapsedLineCount: 1_000_000_000
                    ),
                ]
            ),
        ])
        let collapsedWrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: collapsedModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 120
        )
        let collapsedNoWrapHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: collapsedModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: false,
            availableWidth: 120
        )
        #expect(collapsedWrappedHeight > collapsedNoWrapHeight)

        let expandableContextModel = DiffDisplayModel(filePath: "ExpandableContext.swift", groups: [
            expandableContextGroup(boundary: .above, collapsedLineCount: 1_000_000_000),
        ])
        let expandableContextWrappedHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: expandableContextModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: true,
            availableWidth: 120
        )
        let expandableContextNoWrapHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: expandableContextModel,
            layoutMode: .stacked,
            expandedCollapsedRowIDs: [],
            wrapLines: false,
            availableWidth: 120
        )
        #expect(expandableContextWrappedHeight == expandableContextNoWrapHeight)

        let emptyHunkModel = DiffDisplayModel(filePath: "empty.swift", groups: [
            DiffDisplayGroup(
                id: "empty",
                header: "@@ -1,0 +1,0 @@",
                sourceHunk: baseGroup.sourceHunk,
                rows: []
            ),
        ])
        let defaultHeaderHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: emptyHunkModel,
            layoutMode: .split,
            expandedCollapsedRowIDs: [],
            headerFont: .monospacedSystemFont(ofSize: 12, weight: .regular)
        )
        let largeHeaderHeight = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: emptyHunkModel,
            layoutMode: .split,
            expandedCollapsedRowIDs: [],
            headerFont: .monospacedSystemFont(ofSize: 64, weight: .regular)
        )
        #expect(largeHeaderHeight > defaultHeaderHeight)
    }

    @Test func splitPaneUsesMergeStyleScrollPanesWithLineRulers() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
        let allHaveRulers = splitScrollViews.allSatisfy { scrollView in
            scrollView.verticalRulerView is DiffPaneLineNumberRulerView
        }
        let allRulersVisible = splitScrollViews.allSatisfy { scrollView in
            scrollView.rulersVisible
        }
        let allHorizontallyScrollable = splitScrollViews.allSatisfy { scrollView in
            scrollView.hasHorizontalScroller
        }
        #expect(splitScrollViews.count == 2)
        #expect(allHaveRulers)
        #expect(allRulersVisible)
        #expect(allHorizontallyScrollable)

        let textViews = splitScrollViews.compactMap { $0.documentView as? NSTextView }
        let selectableTextViews = textViews.filter(\.isSelectable)

        #expect(selectableTextViews.count == 2)
        #expect(selectableTextViews.allSatisfy { !$0.isEditable })

        let selectableText = selectableTextViews.map(\.string).joined(separator: "\n")
        #expect(selectableText.contains("let b = 2"))
        #expect(selectableText.contains("let b = 3"))
        #expect(!selectableText.contains("|"))
        #expect(!selectableText.contains("+2"))
        #expect(!selectableText.contains("-2"))
    }

    @Test @MainActor func splitTextDocumentExposesSourceLineMetadataForBothSides() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: reviewAnchorModel(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeViews = visibleCodeTextViews(in: controller.view)
        #expect(codeViews.count == 2)
        let oldCodeView = try #require(codeViews.first)
        let newCodeView = try #require(codeViews.last)

        #expect(oldCodeView.reviewLineAnchor(atRow: 0)?.side == .old)
        #expect(newCodeView.reviewLineAnchor(atRow: 0)?.side == .new)

        let changedAnchor = try #require(newCodeView.reviewLineAnchor(atRow: 1))
        #expect(changedAnchor.path == "Sources/App.swift")
        #expect(changedAnchor.side == .new)
        #expect(changedAnchor.line == 2)
        #expect(changedAnchor.rowIndex == 1)
        #expect(changedAnchor.selectedText == "let b = 3")
    }

    @Test @MainActor func stackedTextDocumentExposesSourceLineMetadataForAddedAndDeletedLines() throws {
        let view = DiffPaneTextDocumentView(
            group: try #require(reviewAnchorModel().groups.first),
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: theme(),
            lspContext: nil
        )

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeView = try #require(visibleCodeTextViews(in: controller.view).first)
        let deletedAnchor = try #require(codeView.reviewLineAnchor(atRow: 1))
        let addedAnchor = try #require(codeView.reviewLineAnchor(atRow: 2))

        #expect(deletedAnchor.path == "Sources/App.swift")
        #expect(deletedAnchor.side == .old)
        #expect(deletedAnchor.line == 2)
        #expect(deletedAnchor.rowIndex == 1)
        #expect(deletedAnchor.selectedText == "let b = 2")

        #expect(addedAnchor.path == "Sources/App.swift")
        #expect(addedAnchor.side == .new)
        #expect(addedAnchor.line == 2)
        #expect(addedAnchor.rowIndex == 2)
        #expect(addedAnchor.selectedText == "let b = 3")
    }

    @Test @MainActor func stackedTextDocumentBuildsMultilineReviewAnchor() throws {
        let view = DiffPaneTextDocumentView(
            group: try #require(reviewAnchorModel().groups.first),
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: theme(),
            lspContext: nil
        )

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeView = try #require(visibleCodeTextViews(in: controller.view).first)
        let anchor = try #require(codeView.reviewLineAnchor(fromRow: 1, toRow: 2))

        #expect(anchor.path == "Sources/App.swift")
        #expect(anchor.side == .unknown)
        #expect(anchor.line == 2)
        #expect(anchor.endLine == 2)
        #expect(anchor.rowIndex == 1)
        #expect(anchor.selectedText == """
let b = 2
let b = 3
""")
    }

    @Test @MainActor func multilineReviewAnchorRejectsSkippedRows() throws {
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,3 +1,3 @@",
            sourceHunk: ParsedDiff.Hunk(header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1, lines: []),
            rows: [
                DiffDisplayRow(
                    id: "row-1",
                    kind: .context,
                    old: nil,
                    new: diffLine(id: "new-1", side: .new, newLine: 1, text: "let first = true"),
                    collapsedLineCount: 0
                ),
                DiffDisplayRow(
                    id: "collapsed",
                    kind: .collapsed,
                    old: nil,
                    new: nil,
                    collapsedLineCount: 3
                ),
                DiffDisplayRow(
                    id: "row-2",
                    kind: .context,
                    old: nil,
                    new: diffLine(id: "new-5", side: .new, newLine: 5, text: "let last = true"),
                    collapsedLineCount: 0
                ),
            ]
        )
        let view = DiffPaneTextDocumentView(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: theme(),
            lspContext: nil
        )

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeView = try #require(visibleCodeTextViews(in: controller.view).first)

        #expect(codeView.reviewLineAnchor(fromRow: 0, toRow: 2) == nil)
    }

    @Test @MainActor func splitMultilineReviewAnchorSkipsOppositeSidePlaceholders() throws {
        let group = DiffDisplayGroup(
            id: "group",
            header: "@@ -1,3 +1,2 @@",
            sourceHunk: ParsedDiff.Hunk(header: "@@ -1,3 +1,2 @@", oldStart: 1, newStart: 1, lines: []),
            rows: [
                DiffDisplayRow(
                    id: "row-1",
                    kind: .context,
                    old: diffLine(id: "old-1", side: .old, oldLine: 1, text: "let first = true"),
                    new: diffLine(id: "new-1", side: .new, newLine: 1, text: "let first = true"),
                    collapsedLineCount: 0
                ),
                DiffDisplayRow(
                    id: "deleted",
                    kind: .delete,
                    old: diffLine(id: "old-2", side: .old, oldLine: 2, text: "let removed = true"),
                    new: nil,
                    collapsedLineCount: 0
                ),
                DiffDisplayRow(
                    id: "row-2",
                    kind: .context,
                    old: diffLine(id: "old-3", side: .old, oldLine: 3, text: "let second = true"),
                    new: diffLine(id: "new-2", side: .new, newLine: 2, text: "let second = true"),
                    collapsedLineCount: 0
                ),
            ]
        )
        let view = DiffPaneTextDocumentView(
            group: group,
            expandedCollapsedRowIDs: [],
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: theme(),
            lspContext: nil
        )

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 820, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeViews = visibleCodeTextViews(in: controller.view)
        let newCodeView = try #require(codeViews.last)
        let anchor = try #require(newCodeView.reviewLineAnchor(fromRow: 0, toRow: 2))

        #expect(anchor.path == "Sources/App.swift")
        #expect(anchor.side == .new)
        #expect(anchor.line == 1)
        #expect(anchor.endLine == 2)
        #expect(anchor.selectedText == """
let first = true
let second = true
""")
    }

    @Test @MainActor func rowHitTestingReturnsLocalReviewAnchorForCodePoint() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: reviewAnchorModel(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            showsToolbar: false,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let newCodeView = try #require(visibleCodeTextViews(in: controller.view).last)
        let changedRowRect = try #require(newCodeView.diffRowRects().dropFirst().first)
        let point = NSPoint(x: changedRowRect.minX + 8, y: changedRowRect.midY)

        let anchor = try #require(newCodeView.reviewLineAnchor(at: point))
        #expect(anchor.path == "Sources/App.swift")
        #expect(anchor.line == 2)
        #expect(anchor.side == .new)
        #expect(anchor.rowIndex == 1)
        #expect(anchor.selectedText == "let b = 3")
    }

    @Test func splitPaneExposesDiffLineTonesForRailsAndPlaceholders() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let codeViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .compactMap { $0.documentView as? DiffPaneCodeTextView }
        #expect(codeViews.count == 2)
        let tones = codeViews.flatMap(\.lineTones)
        #expect(tones.contains(.delete))
        #expect(tones.contains(.add))
        #expect(tones.contains(.context))
    }

    @Test func gutterRowsAlignWithCodeRowsInSplitPane() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)

        for scrollView in splitScrollViews {
            let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
            let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
            let codeRows = codeView.diffRowRects()
            let rulerRows = ruler.diffRowRects()
            let codeFirstLineRects = codeView.diffFirstLineFragmentRects()
            let rulerLabelRects = ruler.labelDrawRects()

            #expect(codeRows.count == rulerRows.count)
            for index in 0..<min(codeRows.count, rulerRows.count) {
                #expect(abs(codeRows[index].minY - rulerRows[index].minY) < 0.5)
                #expect(abs(codeRows[index].height - rulerRows[index].height) < 0.5)
            }
            #expect(codeFirstLineRects.count == rulerLabelRects.count)
            for index in 0..<min(codeFirstLineRects.count, rulerLabelRects.count) {
                let codeCenter = codeFirstLineRects[index].midY
                let labelCenter = rulerLabelRects[index].midY
                #expect(abs(codeCenter - labelCenter) < 0.75)
            }
        }
    }

    @Test func longGutterRowsStayAlignedWithActualCodeLineFragments() throws {
        let theme = theme()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lines = (1...80).map { "let value\($0) = \($0)" }
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: text, attributes: [.font: font]),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 360))

        scrollView.update(
            document: document,
            lineLabels: lines.indices.map { "\($0 + 1)" },
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRects = codeView.diffRowRects()
        let firstLineRects = codeView.diffFirstLineFragmentRects()

        #expect(rowRects.count == lines.count)
        #expect(firstLineRects.count == lines.count)
        for index in lines.indices {
            #expect(abs(rowRects[index].midY - firstLineRects[index].midY) < 0.75)
        }
    }

    @Test func synchronizedRowHeightsPreserveUntouchedTextStorageAttributes() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let lines = [
            "let short = true",
            "let medium = false",
            "let untouched = true",
        ]
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: CenterTypography.paragraphStyle(),
                ]
            ),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))

        scrollView.update(
            document: document,
            lineLabels: ["1", "2", "3"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRects = codeView.diffRowRects()
        #expect(rowRects.count == 3)
        let sentinel = NSAttributedString.Key("DiffPaneRowHeightSentinel")
        let untouchedRange = metadata[2].range
        codeView.textStorage?.addAttribute(sentinel, value: "kept", range: untouchedRange)

        scrollView.synchronizeRowHeights([
            rowRects[0].height + 18,
            rowRects[1].height,
            rowRects[2].height,
        ])

        let value = codeView.textStorage?.attribute(sentinel, at: untouchedRange.location, effectiveRange: nil) as? String
        #expect(value == "kept")
    }

    /// Regression test for a review-flagged edge case: skipping the
    /// unconditional `lineTones` reassignment when it hasn't changed must not
    /// skip invalidating the row-geometry cache when a paragraph style
    /// actually changed. `diffRowRects()` is asserted immediately after
    /// `synchronizeRowHeights` returns, with no intervening AppKit layout
    /// pass, to catch the exact staleness window a caller reading
    /// `documentHeight` later in the same `layout()` pass would hit.
    @Test func synchronizeRowHeightsInvalidatesRowGeometryImmediatelyAfterPadding() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let lines = [
            "let first = true",
            "let second = false",
        ]
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: CenterTypography.paragraphStyle(),
                ]
            ),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))

        scrollView.update(
            document: document,
            lineLabels: ["1", "2"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        // Populate the row-geometry cache with pre-padding measurements,
        // mirroring `synchronizeSplitRowHeights` reading `diffRowRects()`
        // right before calling `synchronizeRowHeights`.
        let rowRects = codeView.diffRowRects()
        #expect(rowRects.count == 2)

        let target = rowRects[0].height + 18
        scrollView.synchronizeRowHeights([target, rowRects[1].height])

        // No `layoutSubtreeIfNeeded()` here: read geometry exactly as a
        // caller later in the same layout pass would, before any further
        // AppKit layout tick could paper over stale cached geometry.
        let paddedRows = codeView.diffRowRects()
        #expect(abs(paddedRows[0].height - target) < 0.5)
    }

    /// Regression test for a review-flagged edge case in the beachball fix: a
    /// row's OWN local wrap count can change on a resize (e.g. widening the
    /// pane lets a previously two-line row fit on one line) while its target
    /// height — driven by the paired old/new row — stays exactly the same.
    /// The applied per-line height must be re-derived from the row's CURRENT
    /// geometry in that case, not left at the stale value computed for the
    /// old wrap count, or the row renders too short and misaligns with its
    /// counterpart.
    @Test func synchronizeRowHeightsRecomputesAfterWrapCountChangesWithStableTarget() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let longLine = "let value = \"padding padding padding padding\""
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: 0, length: (longLine as NSString).length)
            ),
        ]
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: longLine,
                attributes: [
                    .font: font,
                    .paragraphStyle: CenterTypography.paragraphStyle(),
                ]
            ),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 160, height: 200))

        scrollView.update(
            document: document,
            lineLabels: ["1"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let narrowRows = codeView.diffRowRects()
        #expect(narrowRows.count == 1)

        let fontLineHeight = ceil(font.ascender + abs(font.descender) + font.leading)
        let narrowLineCount = max(1, Int(round(narrowRows[0].height / fontLineHeight)))
        #expect(narrowLineCount > 1)

        // Simulate a counterpart on the other side that's one visual line
        // taller than this (currently multi-line-wrapped) row.
        let target = CGFloat(narrowLineCount + 1) * fontLineHeight
        scrollView.synchronizeRowHeights([target])

        let paddedParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(abs(paddedParagraph.minimumLineHeight - target / CGFloat(narrowLineCount)) < 0.5)

        // Widen the pane so the same text now fits on a single visual line.
        // The row's target height (still `target`, as if the counterpart
        // hasn't changed) is unchanged, but the per-line height needed to
        // reach it is no longer `target / 2` — it's `target / 1`.
        scrollView.setFrameSize(NSSize(width: 600, height: 200))
        scrollView.layoutSubtreeIfNeeded()

        scrollView.synchronizeRowHeights([target])
        scrollView.layoutSubtreeIfNeeded()

        let wideRows = codeView.diffRowRects()
        #expect(wideRows.count == 1)
        #expect(abs(wideRows[0].height - target) < 0.5)

        let recomputedParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(abs(recomputedParagraph.minimumLineHeight - target) < 0.5)
    }

    /// Regression test for a second review-flagged edge case: a row wrapped
    /// into many visual fragments can have a genuine target-height change
    /// that's small per line (well under the 0.5pt tolerance) but adds up to
    /// several points across the whole row. Comparing only the per-line delta
    /// would skip the update and leave the row visibly too short; the
    /// comparison must scale by the row's line count so the TOTAL height
    /// delta is what's checked against the tolerance.
    @Test func synchronizeRowHeightsAppliesSmallPerLineDeltasThatAddUpAcrossManyWraps() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let longLine = String(repeating: "padding ", count: 30)
        let metadata = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: 0, length: (longLine as NSString).length)
            ),
        ]
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: longLine,
                attributes: [
                    .font: font,
                    .paragraphStyle: CenterTypography.paragraphStyle(),
                ]
            ),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))

        scrollView.update(
            document: document,
            lineLabels: ["1"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let naturalRows = codeView.diffRowRects()
        #expect(naturalRows.count == 1)

        let fontLineHeight = ceil(font.ascender + abs(font.descender) + font.leading)
        let naturalLineCount = max(1, Int(round(naturalRows[0].height / fontLineHeight)))
        #expect(naturalLineCount >= 7)

        let target1 = CGFloat(naturalLineCount + 2) * fontLineHeight
        scrollView.synchronizeRowHeights([target1])
        scrollView.layoutSubtreeIfNeeded()

        let firstParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        let firstLineHeight = firstParagraph.minimumLineHeight

        // A total target increase small enough that spread across every wrap
        // it's under 0.5pt per line, but it's still several points overall.
        let totalDelta: CGFloat = 3
        #expect(totalDelta / CGFloat(naturalLineCount) < 0.5)
        let target2 = target1 + totalDelta
        scrollView.synchronizeRowHeights([target2])
        scrollView.layoutSubtreeIfNeeded()

        // The row must grow to reflect the new (larger) target — a stale
        // per-line height that only differs by "under 0.5pt" locally would
        // otherwise leave the row under-height by roughly `totalDelta`.
        let rows = codeView.diffRowRects()
        #expect(abs(rows[0].height - target2) < 0.75)

        let secondParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(secondParagraph.minimumLineHeight - firstLineHeight > 0.1)
    }

    /// Regression test for a live-lock (beachball): a row whose target height
    /// permanently differs from its natural height (e.g. its paired old/new
    /// row wraps to a different line count) must keep its custom line-height
    /// paragraph style untouched while some OTHER row's target changes.
    /// Previously, any other row's target change unconditionally stripped
    /// every already-padded row for "remeasurement", which reapplied the same
    /// padding on the very next layout pass — an unbounded
    /// apply/strip/reapply cycle that kept calling
    /// `invalidateIntrinsicContentSize()` forever.
    @Test func synchronizedRowHeightsKeepsStablePaddingWhileOtherRowsChange() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let lines = [
            "let first = true",
            "let second = false",
            "let third = true",
        ]
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: CenterTypography.paragraphStyle(),
                ]
            ),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))

        scrollView.update(
            document: document,
            lineLabels: ["1", "2", "3"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRects = codeView.diffRowRects()
        #expect(rowRects.count == 3)

        // Row 0 permanently needs padding (its paired row on the other side
        // is taller by a whole line) — its target height never changes
        // across any of the following calls.
        let firstInflatedHeight = rowRects[0].height + 18
        scrollView.synchronizeRowHeights([
            firstInflatedHeight,
            rowRects[1].height,
            rowRects[2].height,
        ])

        let paddedParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: metadata[0].range.location, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(paddedParagraph.minimumLineHeight > rowRects[0].height + 0.5)

        // Row 1's target changes; row 0's does not. Row 0's existing padding
        // must be left alone, not stripped back to the base paragraph style.
        scrollView.synchronizeRowHeights([
            firstInflatedHeight,
            rowRects[1].height + 18,
            rowRects[2].height,
        ])

        let unchangedParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: metadata[0].range.location, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(unchangedParagraph.minimumLineHeight > rowRects[0].height + 0.5)

        // Settling further with the same heights must not disturb row 0 either.
        scrollView.layoutSubtreeIfNeeded()
        scrollView.synchronizeRowHeights([
            firstInflatedHeight,
            rowRects[1].height + 18,
            rowRects[2].height,
        ])

        let stillUnchangedParagraph = try #require(
            codeView.textStorage?.attribute(.paragraphStyle, at: metadata[0].range.location, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(stillUnchangedParagraph.minimumLineHeight > rowRects[0].height + 0.5)
    }

    /// Regression test for the beachball: once row heights settle, calling
    /// `synchronizeRowHeights` again with the identical target heights must be
    /// a no-op that doesn't re-trigger a layout pass. If it did, the resulting
    /// `invalidateIntrinsicContentSize()` would schedule another AppKit
    /// layout, which re-enters this same synchronization and never converges
    /// — pegging the main thread at 100% CPU (the live-lock this guards
    /// against).
    @Test func synchronizeRowHeightsIsNoOpOnceStable() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let lines = [
            "let first = true",
            "let second = false",
            "let third = true",
        ]
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: CenterTypography.paragraphStyle(),
                ]
            ),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))

        scrollView.update(
            document: document,
            lineLabels: ["1", "2", "3"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRects = codeView.diffRowRects()
        #expect(rowRects.count == 3)

        let heights = [rowRects[0].height + 18, rowRects[1].height, rowRects[2].height]
        scrollView.synchronizeRowHeights(heights)
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.needsLayout == false)

        scrollView.synchronizeRowHeights(heights)
        #expect(scrollView.needsLayout == false)
    }

    @Test func gutterSelectionOutlineWrapsContiguousRows() {
        let rowRects = [
            NSRect(x: 0, y: 8, width: 42, height: 18),
            NSRect(x: 0, y: 26, width: 42, height: 22),
            NSRect(x: 0, y: 48, width: 42, height: 18),
        ]

        let outline = DiffPaneLineNumberRulerView.selectionOutlineRect(
            rowRects: rowRects,
            rowRange: 0...2,
            visibleMinY: 10,
            ruleThickness: 42
        )

        #expect(outline == NSRect(x: 4, y: 0, width: 34, height: 58))
    }

    @Test func activeCommentGutterHighlightFillsFullGutterRows() {
        let rowRects = [
            NSRect(x: 0, y: 8, width: 42, height: 18),
            NSRect(x: 0, y: 26, width: 42, height: 22),
            NSRect(x: 0, y: 48, width: 42, height: 18),
        ]

        let rect = DiffPaneLineNumberRulerView.activeCommentHighlightRect(
            rowRects: rowRects,
            rowRange: 1...2,
            visibleMinY: 10,
            ruleThickness: 42
        )

        #expect(rect == NSRect(x: 0, y: 16, width: 42, height: 40))
    }

    @Test func activeCommentGutterHighlightClipsRowsScrolledPastTop() {
        let rowRects = [
            NSRect(x: 0, y: 8, width: 42, height: 18),
            NSRect(x: 0, y: 26, width: 42, height: 22),
        ]

        let rect = DiffPaneLineNumberRulerView.activeCommentHighlightRect(
            rowRects: rowRects,
            rowRange: 0...1,
            visibleMinY: 20,
            ruleThickness: 42
        )

        #expect(rect == NSRect(x: 0, y: 0, width: 42, height: 28))
    }

    @Test func activeCommentHighlightMatchesRowsBySideAndLineRange() {
        let lines = [
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: 0, length: 1),
                sourceLine: diffLine(id: "new-10", side: .new, newLine: 10, text: "a")
            ),
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: 2, length: 1),
                sourceLine: diffLine(id: "old-11", side: .old, oldLine: 11, text: "b")
            ),
            DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: 4, length: 1),
                sourceLine: diffLine(id: "new-12", side: .new, newLine: 12, text: "c")
            ),
        ]
        let highlight = DiffReviewCommentHighlight(path: "Sources/App.swift", side: .new, lineRange: 10...12)

        #expect(highlight.highlightedRowRange(in: lines) == 0...2)
    }

    @Test func activeCommentHighlightMatchesPairedRowsByRequestedSideLineNumber() {
        let line = DiffDisplayLine(
            id: "paired-10-12",
            anchor: DiffLineAnchor(
                filePath: "Sources/App.swift",
                hunkIndex: 0,
                rowIndex: 0,
                side: .paired,
                oldLine: 10,
                newLine: 12
            ),
            text: "let value = 1",
            lineNumber: 12,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )

        #expect(DiffReviewCommentHighlight(path: "Sources/App.swift", side: .old, line: 10).matchesVisibleSourceLine(line))
        #expect(DiffReviewCommentHighlight(path: "Sources/App.swift", side: .new, line: 12).matchesVisibleSourceLine(line))
        #expect(!DiffReviewCommentHighlight(path: "Sources/App.swift", side: .old, line: 12).matchesVisibleSourceLine(line))
    }

    @Test func activeCommentHighlightMatchesOnlyVisibleSourceLines() {
        let highlight = DiffReviewCommentHighlight(path: "Sources/App.swift", side: .new, lineRange: 10...12)

        #expect(highlight.matchesVisibleSourceLine(diffLine(id: "new-10", side: .new, newLine: 10, text: "a")))
        #expect(!highlight.matchesVisibleSourceLine(nil))
        #expect(!highlight.matchesVisibleSourceLine(diffLine(id: "old-10", side: .old, oldLine: 10, text: "b")))
    }

    @Test func activeThreadHighlightWinsOverParentHighlightInSameRows() {
        let rows = [
            DiffDisplayRow(
                id: "row-10",
                kind: .context,
                old: diffLine(id: "old-8", side: .old, oldLine: 8, text: "let value = 1"),
                new: diffLine(id: "new-10", side: .new, newLine: 10, text: "let value = 1"),
                collapsedLineCount: 0
            ),
        ]
        let parentHighlight = DiffReviewCommentHighlight(path: "Sources/App.swift", side: .old, line: 8)
        let thread = DiffInlineCommentThread(
            id: "thread-10",
            filePath: "Sources/App.swift",
            newLine: 10,
            isResolved: false,
            isOutdated: false,
            comments: []
        )

        let highlight = DiffPaneActiveHighlightResolver.activeHighlight(
            parentHighlight: parentHighlight,
            threads: [thread],
            activeThreadID: thread.id,
            rows: rows
        )

        #expect(highlight == DiffReviewCommentHighlight(path: "Sources/App.swift", side: .new, line: 10))
    }

    @Test func activeCommentHighlightRectSpansMatchedRows() {
        let rowRects = [
            NSRect(x: 0, y: 8, width: 300, height: 18),
            NSRect(x: 0, y: 26, width: 300, height: 22),
            NSRect(x: 0, y: 48, width: 300, height: 18),
        ]

        let rect = DiffPaneCodeTextView.commentHighlightRect(
            rowRects: rowRects,
            rowRange: 1...2,
            visibleMinY: 10,
            contentWidth: 300
        )

        #expect(rect == NSRect(x: 4, y: 16, width: 292, height: 40))
    }

    @Test func diffTextScrollPanesUseLeadingClipViewsAndStartScrolledLeft() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let scrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
        #expect(scrollViews.isEmpty == false)
        for scrollView in scrollViews {
            #expect(scrollView.contentView is DiffPaneLeadingClipView)
            #expect(abs(scrollView.contentView.bounds.origin.x) < 0.5)
        }
    }

    @Test func diffTextScrollPaneResetsHorizontalOriginWhenLaidOutForInitialDisplay() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = \"This line is intentionally long enough to make the inner pane horizontally scrollable.\""
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .context, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))

        scrollView.update(
            document: document,
            lineLabels: [" 1"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.x > 0)

        scrollView.resetHorizontalOriginToLeading()

        #expect(scrollView.contentView.bounds.origin.x == 0)

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.x > 0)

        scrollView.update(
            document: document,
            lineLabels: [" 1"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )

        #expect(scrollView.contentView.bounds.origin.x == 0)

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(scrollView.contentView.bounds.origin.x > 0)

        scrollView.layoutSubtreeIfNeeded()

        #expect(scrollView.contentView.bounds.origin.x == 0)
    }

    @Test func lineNumberRulerKeepsRowsVisibleAfterHorizontalScroll() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = \"This line is intentionally long enough to make the inner pane horizontally scrollable.\""
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .add, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))

        scrollView.update(
            document: document,
            lineLabels: ["56"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        #expect(scrollView.contentView.bounds.origin.x > 0)
        #expect(ruler.visibleRowIndices(in: scrollView.contentView.bounds) == [0])
    }

    @Test func wrappedDiffTextScrollPaneDoesNotAllowHorizontalOffset() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = \"This line is intentionally long enough to wrap instead of creating an inner horizontal scroll range.\""
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .context, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 80))

        scrollView.update(
            document: document,
            lineLabels: [" 1"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        scrollView.contentView.scroll(to: NSPoint(x: 120, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        #expect(scrollView.hasHorizontalScroller == false)
        #expect(abs(scrollView.contentView.bounds.origin.x) < 0.5)
        #expect(abs(scrollView.documentView!.frame.width - scrollView.contentView.bounds.width) < 0.5)
    }

    @Test func wrappedDiffTextKeepsContinuationGlyphsVisible() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "        guard currentConfigOptions.first(where: { $0.id == configId })?.currentValue == selectedValue else {"
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .add, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 120))

        scrollView.update(
            document: document,
            lineLabels: ["+56"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let layoutManager = try #require(codeView.layoutManager)
        let textContainer = try #require(codeView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let configRange = (text as NSString).range(of: "configId")
        let glyphRange = layoutManager.glyphRange(forCharacterRange: configRange, actualCharacterRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: codeView.textContainerOrigin.x, dy: codeView.textContainerOrigin.y)
        let visibleCodeRect = codeView.visibleRect.insetBy(dx: codeView.textContainerInset.width, dy: 0)

        #expect(glyphRect.minX >= visibleCodeRect.minX - 0.5)
        #expect(glyphRect.maxX <= visibleCodeRect.maxX + 0.5)
    }

    @Test func wrappedDiffTextPaneKeepsCodeViewportAfterLineRuler() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "struct ACPConfigOptionItem: Codable, Equatable, Identifiable {"
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [.init(kind: .context, range: NSRange(location: 0, length: (text as NSString).length))]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 120))

        scrollView.update(
            document: document,
            lineLabels: ["73"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let rulerWidth = try #require(scrollView.verticalRulerView?.ruleThickness)
        #expect(scrollView.contentView.frame.minX >= rulerWidth - 0.5)
    }

    @Test func feedbackLaneWrapperRetainsFullWidthAndHostsMultipleChildren() throws {
        let rows = try #require(model().groups.first?.rows)
        let splitController = NSHostingController(rootView:
            DiffFeedbackLaneView(lane: .left, layoutMode: .split, rows: rows) {
                FrameProbe(identifier: "feedback-child-first")
                    .frame(maxWidth: .infinity)
                    .frame(height: 10)
                FrameProbe(identifier: "feedback-child-second")
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
            }
            .environment(\.theme, theme())
        )
        splitController.view.frame = NSRect(x: 0, y: 0, width: 900, height: 60)
        splitController.view.layoutSubtreeIfNeeded()

        let laneMarker = try #require(subview(
            withAccessibilityIdentifier: "diff-feedback-lane-left",
            in: splitController.view
        ))
        let dividerMarker = try #require(subview(
            withAccessibilityIdentifier: "diff-feedback-divider",
            in: splitController.view
        ))
        let firstChild = try #require(subview(
            withAccessibilityIdentifier: "feedback-child-first",
            in: splitController.view
        ))
        let secondChild = try #require(subview(
            withAccessibilityIdentifier: "feedback-child-second",
            in: splitController.view
        ))
        let laneFrame = laneMarker.convert(laneMarker.bounds, to: splitController.view)
        let dividerFrame = dividerMarker.convert(dividerMarker.bounds, to: splitController.view)
        let firstFrame = firstChild.convert(firstChild.bounds, to: splitController.view)
        let secondFrame = secondChild.convert(secondChild.bounds, to: splitController.view)

        #expect(abs(laneFrame.minX) < 0.01)
        #expect(abs(laneFrame.width - 900) < 0.01)
        #expect(abs(dividerFrame.minX - 449) < 0.01)
        #expect(abs(dividerFrame.width - 1) < 0.01)
        #expect(abs(firstFrame.minX - 42) < 0.01)
        #expect(abs(firstFrame.width - 407) < 0.01)
        #expect(abs(firstFrame.height - 10) < 0.01)
        #expect(abs(secondFrame.minX - 42) < 0.01)
        #expect(abs(secondFrame.width - 407) < 0.01)
        #expect(abs(secondFrame.height - 20) < 0.01)
        #expect(abs(secondFrame.minY - firstFrame.maxY) < 0.01)

        let stackedController = NSHostingController(rootView:
            DiffFeedbackLaneView(lane: .right, layoutMode: .stacked, rows: rows) {
                Color.clear.frame(height: 20)
            }
            .environment(\.theme, theme())
        )
        stackedController.view.frame = NSRect(x: 0, y: 0, width: 901, height: 20)
        stackedController.view.layoutSubtreeIfNeeded()

        #expect(subview(
            withAccessibilityIdentifier: "diff-feedback-lane-full",
            in: stackedController.view
        ) != nil)
    }

    @Test func feedbackLaneDoesNotProbeChildWithUnspecifiedWidth() throws {
        let rows = try #require(model().groups.first?.rows)
        let counter = LayoutMeasurementCounter()
        let controller = NSHostingController(rootView:
            DiffFeedbackLaneView(lane: .right, layoutMode: .split, rows: rows) {
                LayoutMeasurementProbe(counter: counter) {
                    Color.clear
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 20)
            }
            .environment(\.theme, theme())
        )
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 20)

        _ = controller.view.fittingSize

        #expect(
            counter.widthProposals.allSatisfy { $0 != nil },
            "Feedback lane should not ask content for an unspecified ideal width; proposals were \(counter.widthProposals)"
        )
    }

    @Test func feedbackLaneUnspecifiedProposalHasNoIntrinsicContainerWidth() {
        #expect(DiffFeedbackLaneGeometry.containerWidth(for: .unspecified) == 0)
        #expect(DiffFeedbackLaneGeometry.containerWidth(for: .init(width: -12, height: nil)) == 0)
        #expect(DiffFeedbackLaneGeometry.containerWidth(for: .init(width: 900, height: nil)) == 900)
    }

    @Test func diffPreferenceBindingsPersistLayoutButKeepWrapAndWhitespacePaneLocal() {
        let recorder = WriteRecorder()
        let appState = AppState(store: MemoryStore(recorder: recorder))
        appState.config.changes.diffLayoutMode = .split
        var firstWrapLines = false
        var secondWrapLines = false
        var firstWhitespace = false
        var secondWhitespace = false

        let first = DiffPreferenceBindings(
            appState: appState,
            wrapLines: Binding(get: { firstWrapLines }, set: { firstWrapLines = $0 }),
            showWhitespace: Binding(get: { firstWhitespace }, set: { firstWhitespace = $0 })
        )
        first.wrapLines.wrappedValue = true
        #expect(recorder.writeCount == 0)

        first.layoutMode.wrappedValue = .stacked
        #expect(recorder.writeCount == 1)

        first.showWhitespace.wrappedValue = true
        let second = DiffPreferenceBindings(
            appState: appState,
            wrapLines: Binding(get: { secondWrapLines }, set: { secondWrapLines = $0 }),
            showWhitespace: Binding(get: { secondWhitespace }, set: { secondWhitespace = $0 })
        )

        #expect(appState.config.changes.diffLayoutMode == .stacked)
        #expect(first.wrapLines.wrappedValue == true)
        #expect(second.wrapLines.wrappedValue == false)
        #expect(first.showWhitespace.wrappedValue == true)
        #expect(second.showWhitespace.wrappedValue == false)
    }

    @Test func diffTabsProvideDistinctPresentationIdentityForDirectSwitches() {
        let first = DiffTabState(
            id: "first-diff",
            title: "First diff",
            relativePath: "Sources/First.swift"
        )
        let second = DiffTabState(
            id: "second-diff",
            title: "Second diff",
            relativePath: "Sources/Second.swift"
        )

        #expect(first.id != second.id)
    }

    @Test func collapsedContextControllerTogglesHiddenRows() throws {
        let group = try #require(collapsedContextModel().groups.first)
        let collapsedIDs = DiffCollapsedContextController.collapsedRowIDs(in: group)
        #expect(collapsedIDs.isEmpty == false)

        let expandedIDs = DiffCollapsedContextController.toggled(group, expandedIDs: [])
        #expect(collapsedIDs.isSubset(of: expandedIDs))
        #expect(DiffCollapsedContextController.isExpanded(group, expandedIDs: expandedIDs))
        let collapsedSnapshot = DiffPaneRowProjection.visibleRowsSnapshot(
            in: group,
            expandedCollapsedRowIDs: []
        )
        #expect(collapsedSnapshot.rows == group.rows)
        #expect(collapsedSnapshot.signature == group.rowsSignature)

        let expandedSnapshot = DiffPaneRowProjection.visibleRowsSnapshot(
            in: group,
            expandedCollapsedRowIDs: expandedIDs
        )
        #expect(expandedSnapshot.rows.count > group.rows.count)
        #expect(expandedSnapshot.signature != group.rowsSignature)

        let collapsedAgain = DiffCollapsedContextController.toggled(group, expandedIDs: expandedIDs)
        #expect(collapsedAgain.intersection(collapsedIDs).isEmpty)
    }

    @Test func collapsedContextControlRendersInPaneHeader() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: collapsedContextModel(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
        let helpTexts = buttons.compactMap { $0.toolTip }
        #expect(helpTexts.contains("Expand context"))
    }

    @Test func leadingEmptyCounterpartRowsAlignWithCodeRowsInSplitPane() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .add, text: "let inserted = true", oldNumber: nil, newNumber: 1),
                        .init(kind: .context, text: "let c = 3", oldNumber: 1, newNumber: 2),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model,
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(splitScrollViews.count == 2)

        let oldCodeView = try #require(splitScrollViews.first?.documentView as? DiffPaneCodeTextView)
        let newCodeView = try #require(splitScrollViews.last?.documentView as? DiffPaneCodeTextView)
        let oldRows = oldCodeView.diffRowRects()
        let newRows = newCodeView.diffRowRects()
        #expect(oldRows.count == newRows.count)
        #expect(oldRows.count >= 2)
        #expect(abs(oldRows[0].minY - oldCodeView.textContainerInset.height) < 0.5)
        #expect(abs(newRows[0].minY - newCodeView.textContainerInset.height) < 0.5)
        #expect(abs(oldRows[0].minY - newRows[0].minY) < 0.5)
        #expect(abs(oldRows[0].height - newRows[0].height) < 0.5)
        #expect(abs(oldRows[1].minY - newRows[1].minY) < 0.5)
    }

    @Test func wrappedEmptyCounterpartRowsReserveCounterpartHeightInSplitPane() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,4 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(
                            kind: .add,
                            text: "let inserted = \"This is intentionally long enough to wrap inside the split pane so the empty old-side counterpart has to reserve more than one visual line of height.\"",
                            oldNumber: nil,
                            newNumber: 1
                        ),
                        .init(kind: .add, text: "let second = true", oldNumber: nil, newNumber: 2),
                        .init(kind: .add, text: "let third = true", oldNumber: nil, newNumber: 3),
                        .init(kind: .context, text: "let c = 3", oldNumber: 1, newNumber: 4),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        var layout = DiffLayoutMode.split
        var wrap = true
        var whitespace = false
        let view = DiffPaneView(
            model: model,
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in DiffPaneHunkActions() }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let splitScrollViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(splitScrollViews.count == 2)

        let oldCodeView = try #require(splitScrollViews.first?.documentView as? DiffPaneCodeTextView)
        let newCodeView = try #require(splitScrollViews.last?.documentView as? DiffPaneCodeTextView)
        let oldRows = oldCodeView.diffRowRects()
        let newRows = newCodeView.diffRowRects()

        #expect(oldRows.count == newRows.count)
        #expect(oldRows.count >= 4)
        #expect(abs(oldRows[0].minY - oldCodeView.textContainerInset.height) < 0.5)
        #expect(abs(newRows[0].minY - newCodeView.textContainerInset.height) < 0.5)
        for index in oldRows.indices {
            #expect(abs(oldRows[index].minY - newRows[index].minY) < 0.5)
            #expect(abs(oldRows[index].height - newRows[index].height) < 0.5)
            if index > 0 {
                #expect(oldRows[index].minY >= oldRows[index - 1].maxY - 0.5)
                #expect(newRows[index].minY >= newRows[index - 1].maxY - 0.5)
            }
        }
    }

    @Test func diffLineToneClassifiesRailsAndEmptyCounterparts() {
        #expect(DiffPaneLineTone(label: "12", rowKind: .delete) == .delete)
        #expect(DiffPaneLineTone(label: "13", rowKind: .add) == .add)
        #expect(DiffPaneLineTone(label: "", rowKind: .add) == .placeholder)
        #expect(DiffPaneLineTone(label: "", rowKind: .collapsed) == .collapsed)
        #expect(DiffPaneLineTone(label: "8", rowKind: .context) == .context)
    }

    @Test func placeholderHatchIsInsetInsideRowRect() {
        let rowRect = NSRect(x: 0, y: 8, width: 240, height: 22)
        let hatchRect = DiffPaneCodeTextView.placeholderHatchRect(in: rowRect)

        #expect(hatchRect.minY > rowRect.minY)
        #expect(hatchRect.maxY < rowRect.maxY)
        #expect(hatchRect.minX == rowRect.minX)
        #expect(hatchRect.maxX == rowRect.maxX)
    }

    @Test func changeRailsRenderOnlyInLineNumberRuler() {
        let rowRect = NSRect(x: 0, y: 10, width: 120, height: 24)

        #expect(DiffPaneLineNumberRulerView.changeRailRect(in: rowRect, tone: .add) == NSRect(x: 0, y: 10, width: 3, height: 24))
        #expect(DiffPaneLineNumberRulerView.changeRailRect(in: rowRect, tone: .delete) == NSRect(x: 0, y: 10, width: 3, height: 24))
        #expect(DiffPaneLineNumberRulerView.changeRailRect(in: rowRect, tone: .context) == nil)

        #expect(DiffPaneCodeTextView.changeRailRect(in: rowRect, tone: .add) == nil)
        #expect(DiffPaneCodeTextView.changeRailRect(in: rowRect, tone: .delete) == nil)
    }

    @Test func lineNumberRulerColorsExpandableContextPlusAsBoundaryControl() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "9 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: DiffContextExpansionKey(groupID: "hunk-0", boundary: .above),
                    expansionBoundary: .above
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .old
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        let color = try #require(ruler.labelAttributesForTesting(row: 0)[.foregroundColor] as? NSColor)

        #expect(color == NSColor(theme.color("fg-faint")))
        #expect(color != NSColor(theme.color("add")))
    }

    @Test @MainActor func lineNumberRulerInvokesExpansionActionForExpandableRows() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "9 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .above
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .old,
            onContextExpansion: { key, mode, _ in captured = (key, mode) }
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        ruler.invokeExpansionForTesting(row: 0, optionKey: false)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .chunk(size: 10))
    }

    @Test @MainActor func lineNumberRulerOptionClickInvokesFullExpansionForExpandableRows() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .below)
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "7 unchanged lines below",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .below
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, _ in captured = (key, mode) }
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        ruler.invokeExpansionForTesting(row: 0, optionKey: true)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
    }

    @Test @MainActor func lineNumberRulerInvokesSharedBottomExpansionEdge() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "2 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .above,
                    expansionEdge: .bottom
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, edge in captured = (key, mode, edge) }
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        ruler.invokeExpansionForTesting(row: 0, optionKey: false)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .chunk(size: 10))
        #expect(captured?.2 == .bottom)
    }

    @Test @MainActor func lineNumberRulerOptionClickInvokesFullExpansionForSharedEdge() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "2 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .above,
                    expansionEdge: .bottom
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, edge in captured = (key, mode, edge) }
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        ruler.invokeExpansionForTesting(row: 0, optionKey: true)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
        #expect(captured?.2 == .bottom)
    }

    @Test @MainActor func lineNumberRulerInvokesSharedExpandAllWithoutOption() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "Expand all 14 unchanged lines",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 29),
                    expansionKey: key,
                    expansionBoundary: .below,
                    expansionEdge: nil
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, edge in captured = (key, mode, edge) }
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        ruler.invokeExpansionForTesting(row: 0, optionKey: false)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
        #expect(captured?.2 == nil)
    }

    @Test @MainActor func codeTextViewInvokesExpansionActionForExpandableRows() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "9 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .above
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .old,
            onContextExpansion: { key, mode, _ in captured = (key, mode) }
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let windowPoint = textView.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        // Expansion fires on mouse-up (the button models a real press cycle).
        textView.mouseDown(with: event)
        textView.mouseUp(with: upEvent)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .chunk(size: 10))
    }

    @Test @MainActor func codeTextViewOptionClickInvokesFullExpansionForExpandableRows() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .below)
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "7 unchanged lines below",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .below
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, _ in captured = (key, mode) }
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let windowPoint = textView.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        // Expansion fires on mouse-up (the button models a real press cycle).
        textView.mouseDown(with: event)
        textView.mouseUp(with: upEvent)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
    }

    @Test @MainActor func codeTextViewInvokesSharedBottomExpansionEdge() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "2 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .above,
                    expansionEdge: .bottom
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, edge in captured = (key, mode, edge) }
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let windowPoint = textView.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)
        textView.mouseUp(with: upEvent)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .chunk(size: 10))
        #expect(captured?.2 == .bottom)
    }

    @Test @MainActor func codeTextViewOptionClickInvokesFullExpansionForSharedEdge() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "2 unchanged lines above",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 23),
                    expansionKey: key,
                    expansionBoundary: .above,
                    expansionEdge: .bottom
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, edge in captured = (key, mode, edge) }
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let windowPoint = textView.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: .option,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)
        textView.mouseUp(with: upEvent)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
        #expect(captured?.2 == .bottom)
    }

    @Test @MainActor func codeTextViewInvokesSharedExpandAllWithoutOption() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let key = DiffContextExpansionKey.shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1")
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: "Expand all 14 unchanged lines",
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .expandableContext,
                    range: NSRange(location: 0, length: 29),
                    expansionKey: key,
                    expansionBoundary: .below,
                    expansionEdge: nil
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode, DiffContextExpansionEdge?)?

        scrollView.update(
            document: document,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, edge in captured = (key, mode, edge) }
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let windowPoint = textView.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)
        textView.mouseUp(with: upEvent)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
        #expect(captured?.2 == nil)
    }

    @Test @MainActor func codeTextViewInvokesFullExpansionFromSecondInlineAction() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let document = DiffPaneTextDocumentBuilder.buildStacked(
            group: expandableContextGroup(boundary: .below, collapsedLineCount: 0),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: font,
            showWhitespace: false,
            theme: theme
        )
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .below)
        let secondAction = try #require(document.code.lines.first?.expansionActions.first { $0.mode == .all })
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var captured: (DiffContextExpansionKey, DiffContextExpansionMode)?

        scrollView.update(
            document: document.code,
            lineLabels: ["+"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { key, mode, _ in captured = (key, mode) }
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let secondActionRect = try #require(textView.symbolAnchorRect(for: secondAction.range))
        let windowPoint = textView.convert(NSPoint(x: secondActionRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)
        textView.mouseUp(with: upEvent)

        #expect(captured?.0 == key)
        #expect(captured?.1 == .all)
    }

    @Test @MainActor func lineNumberRulerKeepsReviewSelectionForNonExpandableRows() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = 1"
        let anchor = DiffReviewLineAnchor(
            path: "Sources/App.swift",
            side: .new,
            line: 12,
            rowIndex: 0,
            selectedLines: [
                DiffReviewLineAnchor.SelectedLine(side: .new, line: 12, isChange: false),
            ],
            selectedText: text
        )
        let sourceLine = DiffDisplayLine(
            id: "line-12",
            anchor: DiffLineAnchor(
                filePath: anchor.path,
                hunkIndex: 0,
                rowIndex: 0,
                side: .new,
                oldLine: nil,
                newLine: anchor.line
            ),
            text: text,
            lineNumber: anchor.line,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .context,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    sourceLine: sourceLine
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        var expansionInvocations = 0
        var selectedAnchor: DiffReviewLineAnchor?
        scrollView.onReviewLineSelected = { selectedAnchor = $0 }

        scrollView.update(
            document: document,
            lineLabels: ["12"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new,
            onContextExpansion: { _, _, _ in expansionInvocations += 1 }
        )

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        ruler.invokeExpansionForTesting(row: 0, optionKey: false)
        ruler.invokeReviewLineSelectionForTesting(row: 0)

        #expect(expansionInvocations == 0)
        #expect(selectedAnchor == anchor)
    }

    @Test @MainActor func codeTextViewLeavesReviewSelectionToTheGutter() throws {
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let text = "let value = 1"
        let sourceLine = DiffDisplayLine(
            id: "line-12",
            anchor: DiffLineAnchor(
                filePath: "Sources/App.swift",
                hunkIndex: 0,
                rowIndex: 0,
                side: .new,
                oldLine: nil,
                newLine: 12
            ),
            text: text,
            lineNumber: 12,
            kind: .context,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(
                string: text,
                attributes: [.font: font]
            ),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .context,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    sourceLine: sourceLine
                ),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 80))
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(scrollView)
        var selectedAnchor: DiffReviewLineAnchor?
        scrollView.onReviewLineSelected = { selectedAnchor = $0 }

        scrollView.update(
            document: document,
            lineLabels: ["12"],
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let textView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        let rowRect = try #require(textView.diffRowRects().first)
        let windowPoint = textView.convert(NSPoint(x: rowRect.midX, y: rowRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let upEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        NSApp.postEvent(upEvent, atStart: false)

        textView.mouseDown(with: event)

        #expect(selectedAnchor == nil)
    }

    @Test func splitDocumentBuildsSeparateCodeAndGutterColumns() throws {
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model().groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.oldCode.attributedString.string.components(separatedBy: "\n") == [
            "let a = 1",
            "let b = 2",
        ])
        #expect(result.newCode.attributedString.string.components(separatedBy: "\n") == [
            "let a = 1",
            "let b = 3",
        ])
        #expect(result.oldGutter.string.components(separatedBy: "\n") == ["1", "2"])
        #expect(result.newGutter.string.components(separatedBy: "\n") == ["1", "2"])
        #expect(!result.oldCode.attributedString.string.contains("|"))
        #expect(!result.newCode.attributedString.string.contains("|"))
        #expect(result.oldCode.lines.contains { $0.kind == .replacement })
        #expect(result.newCode.lines.contains { $0.kind == .replacement })
    }

    @Test func splitDocumentRendersExpandableContextBoundaryRows() throws {
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: expandableContextGroup(boundary: .above, collapsedLineCount: 9),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        let key = DiffContextExpansionKey(groupID: "hunk-0", boundary: .above)

        #expect(result.oldGutter.string.components(separatedBy: "\n") == ["+"])
        #expect(result.newGutter.string.components(separatedBy: "\n") == [""])
        #expect(result.oldCode.attributedString.string.components(separatedBy: "\n") == ["Expand 9 unchanged lines above      Expand all context"])
        #expect(result.newCode.attributedString.string.components(separatedBy: "\n") == [" "])
        #expect(result.oldCode.lines.count == result.oldGutter.string.components(separatedBy: "\n").count)
        #expect(result.newCode.lines.count == result.newGutter.string.components(separatedBy: "\n").count)
        #expect(result.oldCode.lines.first?.expansionKey == key)
        #expect(result.oldCode.lines.first?.expansionBoundary == .above)
        #expect(result.newCode.lines.first?.expansionKey == key)
        #expect(result.newCode.lines.first?.expansionBoundary == .above)
    }

    @Test func splitDocumentPreservesSharedExpansionEdge() throws {
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: sharedExpandableContextGroup(edge: .bottom, collapsedLineCount: 2),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.oldCode.lines.first?.expansionKey == .shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1"))
        #expect(result.oldCode.lines.first?.expansionBoundary == .above)
        #expect(result.oldCode.lines.first?.expansionEdge == .bottom)
        #expect(result.newCode.lines.first?.expansionEdge == .bottom)
    }

    @Test func splitDocumentRendersSharedExpandAllContextRow() throws {
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: sharedExpandableContextGroup(edge: nil, collapsedLineCount: 4),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.oldCode.attributedString.string.components(separatedBy: "\n") == ["Expand all 4 unchanged lines"])
        #expect(result.oldCode.lines.first?.expansionKey == .shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1"))
        #expect(result.oldCode.lines.first?.expansionBoundary == .below)
        #expect(result.oldCode.lines.first?.expansionEdge == nil)
        #expect(result.newCode.lines.first?.expansionEdge == nil)
    }

    @Test func stackedDocumentRendersExpandableContextBoundaryRows() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: expandableContextGroup(boundary: .below, collapsedLineCount: 7),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.gutter.string.components(separatedBy: "\n") == ["+"])
        #expect(result.code.attributedString.string.components(separatedBy: "\n") == ["Expand 7 unchanged lines below      Expand all context"])
        #expect(result.code.lines.count == result.gutter.string.components(separatedBy: "\n").count)
        #expect(result.code.lines.first?.expansionKey == DiffContextExpansionKey(groupID: "hunk-0", boundary: .below))
        #expect(result.code.lines.first?.expansionBoundary == .below)
    }

    @Test func stackedDocumentPreservesSharedExpansionEdge() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: sharedExpandableContextGroup(edge: .top, collapsedLineCount: 2),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.code.lines.first?.expansionKey == .shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1"))
        #expect(result.code.lines.first?.expansionBoundary == .below)
        #expect(result.code.lines.first?.expansionEdge == .top)
        #expect(result.code.lines.first?.expansionActions.map(\.mode) == [.chunk, .all])
        #expect(result.code.lines.first?.expansionActions.map(\.edge) == [.top, .top])
    }

    @Test func stackedDocumentRendersSharedExpandAllContextRow() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: sharedExpandableContextGroup(edge: nil, collapsedLineCount: 4),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.code.attributedString.string.components(separatedBy: "\n") == ["Expand all 4 unchanged lines"])
        #expect(result.code.lines.first?.expansionKey == .shared(upperGroupID: "hunk-0", lowerGroupID: "hunk-1"))
        #expect(result.code.lines.first?.expansionBoundary == .below)
        #expect(result.code.lines.first?.expansionEdge == nil)
        #expect(result.code.lines.first?.expansionActions.map(\.mode) == [.all])
        #expect(result.code.lines.first?.expansionActions.map(\.edge) == [nil])
    }

    @Test func stackedDocumentRendersChunkAndFullExpansionActionsSideBySide() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: expandableContextGroup(boundary: .below, collapsedLineCount: 0),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        let line = try #require(result.code.lines.first)
        let paragraph = try #require(result.code.attributedString.attribute(
            .paragraphStyle,
            at: line.range.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(result.code.attributedString.string.components(separatedBy: "\n") == ["Expand context below      Expand all context"])
        #expect(result.code.lines.count == 1)
        #expect(line.expansionActions.map(\.mode) == [.chunk, .all])
        #expect(line.expansionActions.map(\.edge) == [line.expansionEdge, line.expansionEdge])
        #expect(paragraph.lineBreakMode == .byClipping)
    }

    @Test func singleDocumentPreservesExpandableContextMetadata() throws {
        let result = DiffPaneTextDocumentBuilder.build(
            group: expandableContextGroup(boundary: .above, collapsedLineCount: 0),
            expandedCollapsedRowIDs: [],
            layoutMode: .split,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.attributedString.string.contains("Expand context above"))
        #expect(result.lines.first?.expansionKey == DiffContextExpansionKey(groupID: "hunk-0", boundary: .above))
        #expect(result.lines.first?.expansionBoundary == .above)
    }

    @Test func stackedDocumentBuildsCodeOnlyTextAndSeparateGutter() throws {
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model().groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        let rows = result.code.attributedString.string.components(separatedBy: "\n")
        #expect(rows == ["let a = 1", "let b = 2", "let b = 3"])
        #expect(result.gutter.string.components(separatedBy: "\n") == ["1", "2", "2"])
        #expect(!result.code.attributedString.string.contains("|"))
        #expect(result.code.lines.contains { $0.kind == .replacement })
    }

    @Test func rowBasedBuildSplitProducesExpectedLineCount() throws {
        let rows = try #require(model().groups.first).rows.prefix(2).map { $0 }
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            rows: rows,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        #expect(result.oldCode.lines.count == 2)
        #expect(result.newCode.lines.count == 2)
    }

    @Test func rowBasedBuildStackedProducesExpectedLineCount() throws {
        let rows = try #require(model().groups.first).rows.prefix(2).map { $0 }
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            rows: rows,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        // context row produces 1 line, replacement row produces 2 stacked lines
        #expect(result.code.lines.count == 3)
    }

    @Test func splitDocumentUsesInvisibleLayoutGlyphsForEmptyCounterparts() throws {
        let model = DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                ParsedDiff.Hunk(
                    header: "@@ -1,1 +1,2 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: [
                        .init(kind: .add, text: "let inserted = true", oldNumber: nil, newNumber: 1),
                        .init(kind: .context, text: "let c = 3", oldNumber: 1, newNumber: 2),
                    ]
                )
            ]),
            filePath: "a.swift"
        )
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )
        let firstLine = try #require(result.oldCode.lines.first)

        #expect(firstLine.kind == .add)
        #expect(firstLine.range.length > 0)
        #expect(result.oldCode.attributedString.string.hasPrefix(" "))
        #expect(result.oldCode.attributedString.attribute(.foregroundColor, at: firstLine.range.location, effectiveRange: nil) as? NSColor == .clear)
    }

    @Test func hunkActionsRenderInPaneHeader() {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: model(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            hunkActions: { _ in
                DiffPaneHunkActions(stage: {}, discard: {}, dropFromCommit: nil)
            }
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
        let helpTexts = buttons.compactMap { $0.toolTip }
        #expect(helpTexts.contains("Stage hunk"))
        #expect(helpTexts.contains("Discard hunk"))
    }

    @Test func extractedHunkRowExpandsCollapsedContextInMountedLegacyPane() throws {
        var layout = DiffLayoutMode.split
        var wrap = false
        var whitespace = false
        let view = DiffPaneView(
            model: collapsedContextModel(),
            fileExtension: "swift",
            layoutMode: Binding(get: { layout }, set: { layout = $0 }),
            wrapLines: Binding(get: { wrap }, set: { wrap = $0 }),
            showWhitespace: Binding(get: { whitespace }, set: { whitespace = $0 }),
            codeFontFamily: "",
            codeFontSize: 13,
            verticalScrollMode: .staticHeight,
            hunkActions: { _ in DiffPaneHunkActions() },
        )
        .environment(\.theme, theme())

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let collapsedCodeViews = visibleCodeTextViews(in: controller.view)
        #expect(collapsedCodeViews.count == 2)
        let collapsedRowCounts = collapsedCodeViews.map(\.lineMetadata.count)
        let expandButton = try #require(allSubviews(of: controller.view).compactMap { $0 as? NSButton }.first {
            $0.toolTip == "Expand context"
        })
        expandButton.performClick(nil)

        let renderDeadline = Date(timeIntervalSinceNow: 1)
        var expandedRowCounts: [Int] = []
        repeat {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            controller.view.layoutSubtreeIfNeeded()
            expandedRowCounts = visibleCodeTextViews(in: controller.view).map(\.lineMetadata.count)
        } while Date() < renderDeadline && expandedRowCounts == collapsedRowCounts

        let buttons = allSubviews(of: controller.view).compactMap { $0 as? NSButton }
        let helpTexts = buttons.compactMap { $0.toolTip }
        #expect(helpTexts.contains("Collapse context"))
        #expect(expandedRowCounts.count == 2)
        #expect(zip(expandedRowCounts, collapsedRowCounts).allSatisfy { expanded, collapsed in
            expanded > collapsed
        })
    }

    @Test func visibleWhitespacePreservesInlineBackgrounds() {
        let rendered = DiffCodeText.attributedString(
            text: "\tlet b = 3",
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            showWhitespace: true,
            inlineSpans: [DiffInlineSpan(start: 9, length: 1)],
            inlineTone: .add,
            theme: theme()
        )

        #expect(rendered.string == "→let·b·=·3")
        #expect((rendered.string as NSString).length == ("\tlet b = 3" as NSString).length)
        #expect(rendered.attribute(.backgroundColor, at: 9, effectiveRange: nil) != nil)
    }

    @Test func splitDocumentHighlightsSyntaxAcrossRowsWithOriginalWhitespaceSource() throws {
        let theme = theme()
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,3 +1,3 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "\t/* start", oldNumber: 1, newNumber: 1),
                    .init(kind: .context, text: "still comment */", oldNumber: 2, newNumber: 2),
                    .init(kind: .context, text: "let value = 1", oldNumber: 3, newNumber: 3),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: true,
            theme: theme
        )
        let rendered = result.newCode.attributedString.string as NSString
        let commentRange = rendered.range(of: "still·comment")
        let commentStart = try #require(commentRange.location != NSNotFound ? commentRange.location : nil)
        let foreground = try #require(result.newCode.attributedString.attribute(
            .foregroundColor,
            at: commentStart,
            effectiveRange: nil
        ) as? NSColor)

        #expect(result.newCode.syntaxSource == "\t/* start\nstill comment */\nlet value = 1")
        #expect(rendered.hasPrefix("→/*·start"))
        #expect(colorComponents(foreground).isClose(to: colorComponents(NSColor(theme.color("fg-faint")))))
    }

    @Test func splitDocumentKeepsContextAndChangedLinesInColumnSyntaxGroup() throws {
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,1 +1,2 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "/* start", oldNumber: 1, newNumber: 1),
                    .init(kind: .add, text: "still comment */", oldNumber: nil, newNumber: 2),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme()
        )

        #expect(result.newCode.lines.count == 2)
        #expect(result.newCode.lines[0].sourceLine?.anchor.side == .new)
        #expect(result.newCode.lines[1].sourceLine?.anchor.side == .new)
        #expect(result.newCode.lines[0].syntaxGroup == result.newCode.lines[1].syntaxGroup)
    }

    @Test func changedLineSyntaxOverridesPartialFileParseErrors() throws {
        let theme = theme()
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -40,2 +40,3 @@",
                oldStart: 40,
                newStart: 40,
                lines: [
                    .init(kind: .context, text: "    someCall(", oldNumber: 40, newNumber: 40),
                    .init(kind: .add, text: "        let changed = 2", oldNumber: nil, newNumber: 41),
                    .init(kind: .context, text: "    )", oldNumber: 41, newNumber: 42),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme
        )
        let rendered = result.newCode.attributedString.string as NSString
        let keywordStart = rendered.range(of: "let changed").location
        let foreground = try #require(result.newCode.attributedString.attribute(
            .foregroundColor,
            at: keywordStart,
            effectiveRange: nil
        ) as? NSColor)

        #expect(colorComponents(foreground).isClose(to: colorComponents(NSColor(theme.color("syntax-keyword")))))
    }

    @Test func stackedDocumentDoesNotCarrySyntaxFromDeletedLinesIntoAddedLines() throws {
        let theme = theme()
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,1 +1,1 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .delete, text: "/* deleted starts", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "let value = 1", oldNumber: nil, newNumber: 1),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme
        )
        let rendered = result.code.attributedString.string as NSString
        let addedStart = rendered.range(of: "let value").location
        let foreground = try #require(result.code.attributedString.attribute(
            .foregroundColor,
            at: addedStart,
            effectiveRange: nil
        ) as? NSColor)

        #expect(colorComponents(foreground).isClose(to: colorComponents(NSColor(theme.color("syntax-keyword")))))
    }

    @Test func stackedDocumentDoesNotCarrySyntaxFromDeletedLinesIntoFollowingContext() throws {
        let theme = theme()
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,2 +1,1 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .delete, text: "/* deleted starts", oldNumber: 1, newNumber: nil),
                    .init(kind: .context, text: "let value = 1", oldNumber: 2, newNumber: 1),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let result = DiffPaneTextDocumentBuilder.buildStacked(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme
        )
        let rendered = result.code.attributedString.string as NSString
        let contextStart = rendered.range(of: "let value").location
        let foreground = try #require(result.code.attributedString.attribute(
            .foregroundColor,
            at: contextStart,
            effectiveRange: nil
        ) as? NSColor)

        #expect(colorComponents(foreground).isClose(to: colorComponents(NSColor(theme.color("syntax-keyword")))))
    }

    @Test func splitDocumentDoesNotCarrySyntaxAcrossCollapsedRows() throws {
        let theme = theme()
        let rows = [
            DiffDisplayRow(
                id: "context-open",
                kind: .context,
                old: diffLine(id: "old-open", side: .paired, oldLine: 1, newLine: 1, text: "/* open"),
                new: diffLine(id: "new-open", side: .paired, oldLine: 1, newLine: 1, text: "/* open"),
                collapsedLineCount: 0
            ),
            DiffDisplayRow(
                id: "collapsed",
                kind: .collapsed,
                old: nil,
                new: nil,
                collapsedLineCount: 8
            ),
            DiffDisplayRow(
                id: "context-after",
                kind: .context,
                old: diffLine(id: "old-after", side: .paired, oldLine: 10, newLine: 10, text: "let value = 1"),
                new: diffLine(id: "new-after", side: .paired, oldLine: 10, newLine: 10, text: "let value = 1"),
                collapsedLineCount: 0
            ),
        ]

        let result = DiffPaneTextDocumentBuilder.buildSplit(
            rows: rows,
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme
        )
        let rendered = result.newCode.attributedString.string as NSString
        let afterStart = rendered.range(of: "let value").location
        let foreground = try #require(result.newCode.attributedString.attribute(
            .foregroundColor,
            at: afterStart,
            effectiveRange: nil
        ) as? NSColor)

        #expect(colorComponents(foreground).isClose(to: colorComponents(NSColor(theme.color("syntax-keyword")))))
    }

    @Test func splitDocumentCarriesSyntaxAcrossAlignmentPlaceholders() throws {
        let theme = theme()
        let diff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,2 +1,3 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "/* open", oldNumber: 1, newNumber: 1),
                    .init(kind: .add, text: "let inserted = 1", oldNumber: nil, newNumber: 2),
                    .init(kind: .context, text: "still comment */", oldNumber: 2, newNumber: 3),
                ]
            ),
        ])
        let model = DiffDisplayModelBuilder.build(diff: diff, filePath: "Sources/App.swift")
        let result = DiffPaneTextDocumentBuilder.buildSplit(
            group: try #require(model.groups.first),
            expandedCollapsedRowIDs: [],
            fileExtension: "swift",
            font: CenterTypography.resolveCodeFont(family: "", size: 13),
            showWhitespace: false,
            theme: theme
        )
        let rendered = result.oldCode.attributedString.string as NSString
        let commentStart = rendered.range(of: "still comment").location
        let foreground = try #require(result.oldCode.attributedString.attribute(
            .foregroundColor,
            at: commentStart,
            effectiveRange: nil
        ) as? NSColor)

        #expect(colorComponents(foreground).isClose(to: colorComponents(NSColor(theme.color("fg-faint")))))
    }

    @Test func stackedProjectionRendersContextRowsOnce() throws {
        let row = try #require(model().groups[0].rows.first)
        #expect(row.kind == .context)
        #expect(row.old?.text == row.new?.text)

        let lines = DiffPaneRowProjection.stackedLines(for: row)

        #expect(lines.map(\.text) == ["let a = 1"])
        #expect(lines.map(\.anchor.side) == [.paired])
    }

    @Test func contextSelectionSurvivesStackedProjection() throws {
        let row = try #require(model().groups[0].rows.first)
        let splitOldContextAnchor = try #require(row.old?.anchor)
        let stackedContextAnchor = try #require(DiffPaneRowProjection.stackedLines(for: row).first?.anchor)

        let selection = DiffSelectionRange(first: splitOldContextAnchor, last: splitOldContextAnchor)

        #expect(selection.contains(stackedContextAnchor))
    }

    @Test func selectionReducerExtendsRangeOnShiftClick() throws {
        let rows = model().groups[0].rows
        let firstAnchor = try #require(rows[0].new?.anchor)
        let lastAnchor = try #require(rows[1].new?.anchor)

        let firstSelection = DiffSelectionController.selection(
            current: nil,
            clicked: firstAnchor,
            extend: false
        )
        #expect(firstSelection.first == firstAnchor)
        #expect(firstSelection.last == firstAnchor)

        let extended = DiffSelectionController.selection(
            current: firstSelection,
            clicked: lastAnchor,
            extend: true
        )
        #expect(extended.first == firstAnchor)
        #expect(extended.last == lastAnchor)
        #expect(extended.normalized.contains(firstAnchor))
        #expect(extended.normalized.contains(lastAnchor))
    }

    @Test func diffLoadTokenInvalidatesOlderLoadForSameKey() {
        let key = "/repo\u{0}Sources/File.swift\u{0}false"
        let first = DiffLoadToken.next(key: key)
        var activeKey: String? = first.key
        var activeID = first.id

        #expect(first.isActive(activeKey: activeKey, activeID: activeID))

        let second = DiffLoadToken.next(key: key)
        activeKey = second.key
        activeID = second.id

        #expect(!first.isActive(activeKey: activeKey, activeID: activeID))
        #expect(second.isActive(activeKey: activeKey, activeID: activeID))
    }

    @Test func diffPaneCodeTextViewStoresLineMetadata() throws {
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: "let value = 1"),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(
                    kind: .add,
                    range: NSRange(location: 0, length: 13),
                    tone: .add,
                    sourceLine: DiffDisplayLine(
                        id: "a.swift:new:0:0",
                        anchor: DiffLineAnchor(filePath: "a.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 3),
                        text: "let value = 1",
                        lineNumber: 3,
                        kind: .add,
                        inlineSpans: [],
                        noTrailingNewline: false
                    )
                )
            ]
        )
        let scrollView = DiffPaneTextScrollView()
        let theme = try Theme.loadBundled(id: "cool-slate")

        scrollView.update(
            document: document,
            lineLabels: ["+3"],
            wraps: false,
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        #expect(codeView.lineMetadata.count == 1)
        #expect(codeView.lineMetadata.first?.sourceLine?.anchor.newLine == 3)
    }

    @Test func diffPaneCodeTextViewCachesMeasuredRowGeometry() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = """
        let first = 1
        let second = 2
        """
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: text, attributes: [.font: font]),
            lines: [
                DiffPaneTextDocumentBuilder.LineMetadata(kind: .context, range: NSRange(location: 0, length: 13)),
                DiffPaneTextDocumentBuilder.LineMetadata(kind: .context, range: NSRange(location: 14, length: 14)),
            ]
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        let theme = try Theme.loadBundled(id: "cool-slate")

        scrollView.update(
            document: document,
            lineLabels: [" 1", " 2"],
            wraps: true,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)

        _ = codeView.diffRowRects()
        _ = codeView.diffRowRects()
        _ = codeView.diffFirstLineFragmentRects()
        _ = codeView.diffFirstLineFragmentRects()

        #expect(codeView.rowGeometryComputationCountForTesting == 1)

        codeView.setFrameSize(NSSize(width: 260, height: codeView.frame.height))
        _ = codeView.diffRowRects()

        #expect(codeView.rowGeometryComputationCountForTesting == 2)
    }

    @Test func identicalDiffDocumentContainerUpdateDoesNotRequestLayout() throws {
        let group = try #require(model().groups.first)
        let container = DiffPaneTextDocumentContainerView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 300)
        )

        func update() {
            container.update(
                group: group,
                expandedCollapsedRowIDs: [],
                layoutMode: .stacked,
                wrapLines: true,
                showWhitespace: false,
                fileExtension: "swift",
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                theme: theme(),
                lspContext: nil
            )
        }

        update()
        container.layoutSubtreeIfNeeded()
        #expect(!container.needsLayout)

        let codeView = try #require(allSubviews(of: container)
            .compactMap { $0 as? DiffPaneCodeTextView }
            .first(where: isEffectivelyVisible))
        _ = codeView.diffRowRects()
        let geometryComputations = codeView.rowGeometryComputationCountForTesting

        update()

        #expect(!container.needsLayout)
        container.layoutSubtreeIfNeeded()
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations)
    }

    @Test func unchangedGroupContainerUpdateDoesNotInvalidateCommentHighlightViews() throws {
        let group = try #require(model().groups.first)
        let container = DiffPaneTextDocumentContainerView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 300)
        )
        let highlight = DiffReviewCommentHighlight(path: "a.swift", side: .new, line: 2)

        func update() {
            container.update(
                group: group,
                expandedCollapsedRowIDs: [],
                layoutMode: .split,
                wrapLines: false,
                showWhitespace: false,
                fileExtension: "swift",
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                theme: theme(),
                lspContext: nil,
                activeCommentHighlight: highlight
            )
        }

        update()
        let codeViews = allSubviews(of: container).compactMap { $0 as? DiffPaneCodeTextView }
        let rulers = allSubviews(of: container).compactMap { $0 as? DiffPaneLineNumberRulerView }
        #expect(!codeViews.isEmpty)
        #expect(!rulers.isEmpty)
        codeViews.forEach { $0.needsDisplay = false }
        rulers.forEach { $0.needsDisplay = false }

        update()

        #expect(codeViews.allSatisfy { !$0.needsDisplay })
        #expect(rulers.allSatisfy { !$0.needsDisplay })
    }

    @Test func unchangedRowsContainerUpdateDoesNotInvalidateCommentHighlightViews() throws {
        let rows = Array(try #require(model().groups.first).rows)
        let container = DiffPaneTextDocumentContainerView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 300)
        )
        let highlight = DiffReviewCommentHighlight(path: "a.swift", side: .new, line: 2)

        func update() {
            container.update(
                rows: rows,
                layoutMode: .split,
                wrapLines: false,
                showWhitespace: false,
                fileExtension: "swift",
                font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                theme: theme(),
                lspContext: nil,
                activeCommentHighlight: highlight
            )
        }

        update()
        let codeViews = allSubviews(of: container).compactMap { $0 as? DiffPaneCodeTextView }
        let rulers = allSubviews(of: container).compactMap { $0 as? DiffPaneLineNumberRulerView }
        #expect(!codeViews.isEmpty)
        #expect(!rulers.isEmpty)
        codeViews.forEach { $0.needsDisplay = false }
        rulers.forEach { $0.needsDisplay = false }

        update()

        #expect(codeViews.allSatisfy { !$0.needsDisplay })
        #expect(rulers.allSatisfy { !$0.needsDisplay })
    }

    @Test func stableWidthLayoutAppliesTextLayoutConfigurationOnce() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: true)

        scrollView.layout()
        scrollView.layout()
        scrollView.layout()

        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == 1)
    }

    @Test func stableLayoutDoesNotReassignHorizontalScrollerVisibility() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: true)
        let visibilityChangesAfterUpdate = scrollView.horizontalScrollerVisibilityChangeCountForTesting

        scrollView.layout()
        scrollView.layout()
        scrollView.layout()

        #expect(scrollView.horizontalScrollerVisibilityChangeCountForTesting == visibilityChangesAfterUpdate)
    }

    @Test func unwrappedOuterWidthChangeKeepsFixedTextLayoutConfiguration() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: false)
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let geometryComputations = codeView.rowGeometryComputationCountForTesting
        let textViewWidth = codeView.frame.width

        scrollView.setFrameSize(NSSize(width: 280, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()

        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications)
        #expect(codeView.frame.width == textViewWidth)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations)
        #expect(scrollView.hasHorizontalScroller)
    }

    @Test func unwrappedPresentationWidthChangeRecomputesRowGeometryOnce() throws {
        let scrollView = makeTextScrollView(
            width: 220,
            wraps: false,
            lines: ["let value = 1", "return value"]
        )
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let geometryComputations = codeView.rowGeometryComputationCountForTesting
        let textViewWidth = codeView.frame.width

        scrollView.setFrameSize(NSSize(width: 280, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()

        #expect(codeView.frame.width > textViewWidth + 0.5)
        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations + 1)
        let rowRect = try #require(codeView.diffRowRects().first)
        let firstLineFragmentRect = try #require(codeView.diffFirstLineFragmentRects().first)
        let presentationWidth = presentationGeometryWidth(of: codeView)
        #expect(abs(rowRect.width - presentationWidth) < 0.001)
        #expect(abs(firstLineFragmentRect.width - presentationWidth) < 0.001)
    }

    @Test func changingFromWrappedToUnwrappedReconfiguresLayoutAndScrollerOnce() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: true)
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let visibilityChanges = scrollView.horizontalScrollerVisibilityChangeCountForTesting

        updateLongTextScrollView(scrollView, wraps: false)
        scrollView.layout()
        scrollView.layout()

        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications + 1)
        #expect(scrollView.horizontalScrollerVisibilityChangeCountForTesting == visibilityChanges + 1)
        #expect(scrollView.hasHorizontalScroller)
        let rowRect = try #require(codeView.diffRowRects().first)
        let firstLineFragmentRect = try #require(codeView.diffFirstLineFragmentRects().first)
        let presentationWidth = presentationGeometryWidth(of: codeView)
        #expect(abs(rowRect.width - presentationWidth) < 0.001)
        #expect(abs(firstLineFragmentRect.width - presentationWidth) < 0.001)
    }

    @Test func cumulativeUnwrappedWidthChangeRecomputesGeometryFromCachedPresentationWidth() throws {
        let scrollView = makeTextScrollView(
            width: 220,
            wraps: false,
            lines: ["let value = 1", "return value"]
        )
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let geometryComputations = codeView.rowGeometryComputationCountForTesting
        let presentationWidth = codeView.frame.width

        scrollView.setFrameSize(NSSize(width: 220.3, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()
        let subToleranceWidth = codeView.frame.width

        #expect(subToleranceWidth > presentationWidth)
        #expect(subToleranceWidth <= presentationWidth + 0.5)
        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations)

        scrollView.setFrameSize(NSSize(width: 220.6, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()

        #expect(codeView.frame.width > presentationWidth + 0.5)
        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations + 1)
        let rowRect = try #require(codeView.diffRowRects().first)
        #expect(abs(rowRect.width - presentationGeometryWidth(of: codeView)) < 0.001)
    }

    @Test func subHalfPointOuterWidthChangeKeepsAppliedConfigurationAndRowGeometry() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: true)
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let geometryComputations = codeView.rowGeometryComputationCountForTesting
        let contentWidth = scrollView.contentView.bounds.width
        // Exercise the scroll view's frame assignment rather than incidental clip-view autoresizing.
        codeView.autoresizingMask = []

        scrollView.setFrameSize(NSSize(width: 220.3, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()

        #expect(scrollView.contentView.bounds.width > contentWidth)
        #expect(abs(codeView.frame.width - scrollView.contentView.bounds.width) < 0.001)
        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations)
    }

    @Test func cumulativeWidthChangeUsesLastAppliedConfigurationAndRecomputesGeometryOnce() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: true)
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let geometryComputations = codeView.rowGeometryComputationCountForTesting
        let contentWidth = scrollView.contentView.bounds.width

        scrollView.setFrameSize(NSSize(width: 220.3, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()
        scrollView.setFrameSize(NSSize(width: 220.6, height: 120))
        scrollView.needsLayout = true
        scrollView.layout()

        #expect(scrollView.contentView.bounds.width > contentWidth + 0.5)
        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications + 1)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations + 1)
    }

    @Test func heightOnlyOuterResizeKeepsWidthDependentLayoutCaches() throws {
        let scrollView = makeLongTextScrollView(width: 220, wraps: true)
        scrollView.layout()
        let codeView = try #require(scrollView.documentView as? DiffPaneCodeTextView)
        _ = codeView.diffRowRects()
        let configurationApplications = scrollView.textLayoutConfigurationApplicationCountForTesting
        let geometryComputations = codeView.rowGeometryComputationCountForTesting
        let textViewWidth = codeView.frame.width

        scrollView.setFrameSize(NSSize(width: 220, height: 180))
        scrollView.needsLayout = true
        scrollView.layout()

        #expect(codeView.frame.width == textViewWidth)
        #expect(scrollView.textLayoutConfigurationApplicationCountForTesting == configurationApplications)
        #expect(codeView.rowGeometryComputationCountForTesting == geometryComputations)
    }

    @Test func lineNumberRulerDoesNotPaintOverAdjacentCode() throws {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        parent.clipsToBounds = true
        let scrollView = NSScrollView(frame: parent.bounds)
        let ruler = DiffPaneLineNumberRulerView(scrollView: scrollView)
        ruler.update(
            labels: [], lineTones: [], rowHeight: 20, contentTopInset: 0,
            theme: try Theme.loadBundled(id: "cool-slate"),
            expansionRequests: [], activeCommentHighlight: nil,
            onContextExpansion: { _, _, _ in }
        )
        parent.addSubview(ruler)
        ruler.frame = NSRect(x: 0, y: 0, width: 42, height: 200)
        ruler.clipsToBounds = false
        #expect(ruler.visibleRect.width > ruler.bounds.width)

        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSColor.magenta.setFill()
        parent.bounds.fill()

        ruler.drawHashMarksAndLabels(in: parent.bounds)

        let codePixel = try #require(bitmap.colorAt(x: 200, y: 100)?.usingColorSpace(.deviceRGB))
        #expect(codePixel.redComponent > 0.9)
        #expect(codePixel.greenComponent < 0.1)
        #expect(codePixel.blueComponent > 0.9)
        let gutterPixel = try #require(bitmap.colorAt(x: 20, y: 100)?.usingColorSpace(.deviceRGB))
        #expect(gutterPixel.redComponent < 0.9)
    }

    @Test func lineNumberRulerDrawsOnlyDirtyRowsInTallHunks() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 20_000))
        scrollView.documentView = NSView(frame: scrollView.bounds)
        let ruler = DiffPaneLineNumberRulerView(scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler.update(
            labels: (1...1_000).map(String.init),
            lineTones: Array(repeating: .context, count: 1_000),
            rowHeight: 20,
            contentTopInset: 0,
            theme: try Theme.loadBundled(id: "cool-slate"),
            expansionRequests: [],
            activeCommentHighlight: nil,
            onContextExpansion: { _, _, _ in }
        )
        scrollView.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try #require(NSGraphicsContext(bitmapImageRep: bitmap))

        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 4_005, width: 60, height: 90))

        #expect(ruler.drawnRowCountForTesting == 5)

        let outerScrollView = AppKitDiffScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 90))
        outerScrollView.flippedDocumentView.addSubview(scrollView)
        outerScrollView.setDocumentHeight(20_000)
        outerScrollView.layoutSubtreeIfNeeded()
        outerScrollView.setScrollY(4_005, animated: false)
        #expect(abs(ruler.visibleRect.minY - 4_005) < 0.5)
        #expect(ruler.visibleRect.height == 90)

        ruler.drawHashMarksAndLabels(in: ruler.bounds)
        #expect(ruler.drawnRowCountForTesting == 5)

        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 0, width: 60, height: 90))
        #expect(ruler.drawnRowCountForTesting == 0)

        scrollView.removeFromSuperview()
        scrollView.documentView?.setFrameSize(NSSize(width: 1_000, height: 40_000))
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 100, y: 19_995))
        ruler.drawHashMarksAndLabels(in: NSRect(x: 0, y: 0, width: 60, height: 90))
        #expect(ruler.drawnRowCountForTesting == 1)
    }

    @Test func diffPaneLineNumberRulerCachesMappedRowGeometryForVisibleLookups() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lines = (1...80).map { "let value\($0) = \($0)" }
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: text, attributes: [.font: font]),
            lines: metadata
        )
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        let theme = try Theme.loadBundled(id: "cool-slate")

        scrollView.update(
            document: document,
            lineLabels: lines.indices.map { "\($0 + 1)" },
            wraps: false,
            font: font,
            theme: theme,
            lspContext: nil,
            allowedLSPSide: .new
        )
        scrollView.layoutSubtreeIfNeeded()

        let ruler = try #require(scrollView.verticalRulerView as? DiffPaneLineNumberRulerView)
        let visibleRect = NSRect(x: 0, y: 120, width: 420, height: 80)

        let firstVisibleRows = ruler.visibleRowIndices(in: visibleRect)
        _ = ruler.diffRowRects()
        _ = ruler.labelDrawRects()
        let secondVisibleRows = ruler.visibleRowIndices(in: visibleRect)

        #expect(!firstVisibleRows.isEmpty)
        #expect(firstVisibleRows == secondVisibleRows)
        #expect(ruler.rowGeometryComputationCountForTesting == 1)
    }

    @Test func diffPaneCodeTextViewResolvesSymbolsFromPoints() throws {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
        textView.textStorage?.setAttributedString(NSAttributedString(string: "let value = service.fetch()"))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let expectedRange = NSRange(location: 4, length: 5)
        let anchorRect = try #require(textView.symbolAnchorRect(for: expectedRange))
        let point = NSPoint(x: anchorRect.midX, y: anchorRect.midY)

        let characterIndex = try #require(textView.characterIndex(at: point))
        let symbolRange = try #require(textView.symbolRange(at: point))

        #expect(expectedRange.contains(characterIndex))
        #expect(symbolRange == expectedRange)
        #expect(anchorRect.width > 0)
        #expect(anchorRect.height > 0)
    }

    @Test func diffPaneCodeTextViewHitTestingIgnoresPointsLeftOfText() throws {
        let textView = makeDiffPaneCodeTextView(string: "let value = 1")
        let textRect = try firstGlyphRect(in: textView, range: NSRange(location: 0, length: 3))
        let point = NSPoint(x: textView.textContainerInset.width - 2, y: textRect.midY)

        #expect(textView.characterIndex(at: point) == nil)
    }

    @Test func diffPaneCodeTextViewHitTestingIgnoresPointsRightOfLineText() throws {
        let textView = makeDiffPaneCodeTextView(string: "short\nlet muchLongerValue = 1")
        let firstLineRect = try firstGlyphRect(in: textView, range: NSRange(location: 0, length: 5))
        let point = NSPoint(x: firstLineRect.maxX + 20, y: firstLineRect.midY)

        #expect(textView.characterIndex(at: point) == nil)
    }

    @Test func diffPaneCodeTextViewHitTestingIgnoresPointsBelowText() throws {
        let textView = makeDiffPaneCodeTextView(string: "let value = 1")
        let textRect = try firstGlyphRect(in: textView, range: NSRange(location: 0, length: 3))
        let point = NSPoint(x: textRect.midX, y: textRect.maxY + 30)

        #expect(textView.characterIndex(at: point) == nil)
    }

    @Test func diffPaneCodeTextViewUpdateTrackingAreasPreservesExternalTrackingAreas() {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
        let owner = NSObject()
        let externalArea = NSTrackingArea(
            rect: textView.bounds,
            options: [.mouseMoved, .activeInActiveApp],
            owner: owner,
            userInfo: nil
        )
        textView.addTrackingArea(externalArea)

        textView.updateTrackingAreas()

        #expect(textView.trackingAreas.contains { $0 === externalArea })
    }

    @Test func diffPaneCodeTextViewRoutesCommandClickToHandler() throws {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: NSTextContainer())
        let window = NSWindow(contentRect: textView.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)
        textView.textStorage?.setAttributedString(NSAttributedString(string: "let value = service.fetch()"))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        var clickedPoint: NSPoint?
        textView.commandClickHandler = { clickedPoint = $0 }

        let anchorRect = try #require(textView.symbolAnchorRect(for: NSRange(location: 4, length: 5)))
        let windowPoint = textView.convert(NSPoint(x: anchorRect.midX, y: anchorRect.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        textView.mouseDown(with: event)

        let point = try #require(clickedPoint)
        #expect(abs(point.x - anchorRect.midX) < 0.5)
        #expect(abs(point.y - anchorRect.midY) < 0.5)
    }

    @Test func containerViewUpdateRowsProducesPositiveHeightForOneRow() throws {
        let rows = try [#require(model().groups.first?.rows.first)]
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)

        let nsView = DiffPaneTextDocumentContainerView()
        nsView.update(
            rows: rows,
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: font,
            theme: theme,
            lspContext: nil
        )
        nsView.setFrameSize(NSSize(width: 800, height: 1))
        nsView.layout()

        #expect(nsView.intrinsicContentSize.height > 0)
    }

    @Test func containerViewUsesSharedSplitFramesAtEvenAndSubDividerWidths() throws {
        let nsView = DiffPaneTextDocumentContainerView()

        nsView.setFrameSize(NSSize(width: 900, height: 20))
        nsView.layout()
        let oldPane = try #require(nsView.subviews.first)
        let newPane = try #require(nsView.subviews.dropFirst().first)
        let divider = try #require(nsView.subviews.last)
        #expect(oldPane.frame.minX == 0)
        #expect(oldPane.frame.width == 449)
        #expect(divider.frame.minX == 449)
        #expect(divider.frame.width == 1)
        #expect(newPane.frame.minX == 450)
        #expect(newPane.frame.width == 450)

        nsView.setFrameSize(NSSize(width: 0.5, height: 20))
        nsView.layout()
        #expect(oldPane.frame.minX == 0)
        #expect(oldPane.frame.width == 0)
        #expect(divider.frame.minX == 0)
        #expect(divider.frame.width == 0.5)
        #expect(newPane.frame.minX == 0.5)
        #expect(newPane.frame.width == 0)
    }

    @Test func containerViewUpdateRowsProducesPositiveHeightForThreeRows() throws {
        let group = try #require(model().groups.first)
        let rows = Array(group.rows.prefix(3))
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)

        let nsView = DiffPaneTextDocumentContainerView()
        nsView.update(
            rows: rows,
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: font,
            theme: theme,
            lspContext: nil
        )
        nsView.setFrameSize(NSSize(width: 800, height: 1))
        nsView.layout()

        #expect(nsView.intrinsicContentSize.height > 0)
    }

    @Test func containerViewUpdateRowsStackedModeProducesPositiveHeight() throws {
        let rows = Array(try #require(model().groups.first).rows)
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)

        let nsView = DiffPaneTextDocumentContainerView()
        nsView.update(
            rows: rows,
            layoutMode: .stacked,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: font,
            theme: theme,
            lspContext: nil
        )
        nsView.setFrameSize(NSSize(width: 800, height: 1))
        nsView.layout()

        #expect(nsView.intrinsicContentSize.height > 0)
    }

    @Test @MainActor func unchangedContainerUpdateRefreshesContextExpansionHandler() {
        let group = expandableContextGroup(boundary: .above, collapsedLineCount: 9)
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let nsView = DiffPaneTextDocumentContainerView()
        var firstHandlerInvocations = 0
        var secondHandlerInvocations = 0

        func update(handler: @escaping DiffContextExpansionHandler) {
            nsView.update(
                group: group,
                expandedCollapsedRowIDs: [],
                layoutMode: .split,
                wrapLines: false,
                showWhitespace: false,
                fileExtension: "swift",
                font: font,
                theme: theme,
                lspContext: nil,
                onContextExpansion: handler
            )
        }

        update { _, _, _ in firstHandlerInvocations += 1 }
        update { _, _, _ in secondHandlerInvocations += 1 }
        nsView.invokeExpansionForTesting(row: 0, side: .old)

        #expect(firstHandlerInvocations == 0)
        #expect(secondHandlerInvocations == 1)
    }

    @Test func containerViewLayoutDoesNotInvalidateAncestorConstraints() throws {
        let rows = Array(try #require(model().groups.first).rows)
        let theme = theme()
        let font = CenterTypography.resolveCodeFont(family: "", size: 13)
        let parent = ConstraintInvalidationCountingView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let nsView = DiffPaneTextDocumentContainerView(frame: parent.bounds)
        parent.addSubview(nsView)

        nsView.update(
            rows: rows,
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            font: font,
            theme: theme,
            lspContext: nil
        )
        parent.constraintInvalidationCount = 0

        nsView.layout()

        #expect(parent.constraintInvalidationCount == 0)
    }

    @Test func diffPaneSegmentViewHostsContainerViewWithoutCrashing() throws {
        let rows = Array(try #require(model().groups.first).rows)
        let theme = theme()

        let view = DiffPaneSegmentView(
            rows: rows,
            layoutMode: .split,
            wrapLines: false,
            showWhitespace: false,
            fileExtension: "swift",
            codeFontFamily: "",
            codeFontSize: 13,
            theme: theme,
            lspContext: nil,
            onContextExpansion: { _, _, _ in }
        )

        let controller = NSHostingController(rootView: view)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        controller.view.layoutSubtreeIfNeeded()

        let containerViews = allSubviews(of: controller.view)
            .compactMap { $0 as? DiffPaneTextDocumentContainerView }
        #expect(!containerViews.isEmpty)
    }

    @Test func diffPaneCodeTextViewShowsPointingHandOverExpandableContextRow() throws {
        let expansionKey = DiffContextExpansionKey(groupID: "g", boundary: .below)
        let metadata = DiffPaneTextDocumentBuilder.LineMetadata(
            kind: .expandableContext,
            range: NSRange(location: 0, length: 22),
            expansionKey: expansionKey,
            expansionBoundary: .below
        )
        let textView = makeDiffPaneCodeTextView(
            string: "      Expand context below\n",
            metadata: [metadata]
        )
        let window = addToWindow(textView)

        let rowRect = try #require(textView.diffRowRects().first)
        let event = try #require(mouseMovedEvent(in: textView, at: NSPoint(x: rowRect.midX, y: rowRect.midY), window: window))

        NSCursor.arrow.set()
        textView.mouseMoved(with: event)

        #expect(NSCursor.current == NSCursor.pointingHand)
    }

    @Test func diffPaneCodeTextViewShowsIBeamOverSelectableSourceCode() throws {
        let sourceLine = DiffDisplayLine(
            id: "a.swift:new:0:0",
            anchor: DiffLineAnchor(filePath: "a.swift", hunkIndex: 0, rowIndex: 0, side: .new, oldLine: nil, newLine: 1),
            text: "let value = 1",
            lineNumber: 1,
            kind: .add,
            inlineSpans: [],
            noTrailingNewline: false
        )
        let metadata = DiffPaneTextDocumentBuilder.LineMetadata(
            kind: .add,
            range: NSRange(location: 0, length: 14),
            tone: .add,
            sourceLine: sourceLine
        )
        let textView = makeDiffPaneCodeTextView(
            string: "let value = 1\n",
            metadata: [metadata]
        )
        let window = addToWindow(textView)

        let rowRect = try #require(textView.diffRowRects().first)
        let event = try #require(mouseMovedEvent(in: textView, at: NSPoint(x: rowRect.midX, y: rowRect.midY), window: window))

        NSCursor.arrow.set()
        textView.mouseMoved(with: event)

        #expect(NSCursor.current == NSCursor.iBeam)
    }

    @Test func diffPaneCodeTextViewDoesNotShowPointingHandOverNonInteractiveRow() throws {
        let metadata = DiffPaneTextDocumentBuilder.LineMetadata(
            kind: .context,
            range: NSRange(location: 0, length: 1)
        )
        let textView = makeDiffPaneCodeTextView(
            string: " \n",
            metadata: [metadata]
        )
        let window = addToWindow(textView)

        let rowRect = try #require(textView.diffRowRects().first)
        let event = try #require(mouseMovedEvent(in: textView, at: NSPoint(x: rowRect.midX, y: rowRect.midY), window: window))

        NSCursor.arrow.set()
        textView.mouseMoved(with: event)

        #expect(NSCursor.current != NSCursor.pointingHand)
    }

    @Test func diffPaneCodeTextViewResetsPointingHandOnMouseExit() throws {
        let expansionKey = DiffContextExpansionKey(groupID: "g", boundary: .below)
        let metadata = DiffPaneTextDocumentBuilder.LineMetadata(
            kind: .expandableContext,
            range: NSRange(location: 0, length: 22),
            expansionKey: expansionKey,
            expansionBoundary: .below
        )
        let textView = makeDiffPaneCodeTextView(
            string: "      Expand context below\n",
            metadata: [metadata]
        )
        let window = addToWindow(textView)

        let rowRect = try #require(textView.diffRowRects().first)
        let movedEvent = try #require(mouseMovedEvent(in: textView, at: NSPoint(x: rowRect.midX, y: rowRect.midY), window: window))
        let exitEvent = try #require(NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))

        NSCursor.arrow.set()
        textView.mouseMoved(with: movedEvent)
        #expect(NSCursor.current == NSCursor.pointingHand)

        textView.mouseExited(with: exitEvent)
        #expect(NSCursor.current != NSCursor.pointingHand)
    }

    private func makeLongTextScrollView(width: CGFloat, height: CGFloat = 120, wraps: Bool) -> DiffPaneTextScrollView {
        makeTextScrollView(
            width: width,
            height: height,
            wraps: wraps,
            lines: [
                "let firstValue = service.fetchAnIntentionallyLongValueForWrappedLayoutTesting()",
                "let secondValue = service.fetchAnotherIntentionallyLongValueForWrappedLayoutTesting()",
            ]
        )
    }

    private func presentationGeometryWidth(of codeView: DiffPaneCodeTextView) -> CGFloat {
        max(codeView.bounds.width, codeView.visibleRect.width)
    }

    private func updateLongTextScrollView(_ scrollView: DiffPaneTextScrollView, wraps: Bool) {
        updateTextScrollView(
            scrollView,
            wraps: wraps,
            lines: [
                "let firstValue = service.fetchAnIntentionallyLongValueForWrappedLayoutTesting()",
                "let secondValue = service.fetchAnotherIntentionallyLongValueForWrappedLayoutTesting()",
            ]
        )
    }

    private func makeTextScrollView(
        width: CGFloat,
        height: CGFloat = 120,
        wraps: Bool,
        lines: [String]
    ) -> DiffPaneTextScrollView {
        let scrollView = DiffPaneTextScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        updateTextScrollView(scrollView, wraps: wraps, lines: lines)
        return scrollView
    }

    private func updateTextScrollView(_ scrollView: DiffPaneTextScrollView, wraps: Bool, lines: [String]) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let text = lines.joined(separator: "\n")
        var location = 0
        let metadata = lines.map { line in
            defer { location += (line as NSString).length + 1 }
            return DiffPaneTextDocumentBuilder.LineMetadata(
                kind: .context,
                range: NSRange(location: location, length: (line as NSString).length)
            )
        }
        let document = DiffPaneTextDocumentBuilder.CodeDocument(
            attributedString: NSAttributedString(string: text, attributes: [.font: font]),
            lines: metadata
        )

        scrollView.update(
            document: document,
            lineLabels: ["1", "2"],
            wraps: wraps,
            font: font,
            theme: theme(),
            lspContext: nil,
            allowedLSPSide: .new
        )
    }

    private func makeDiffPaneCodeTextView(string: String, metadata: [DiffPaneTextDocumentBuilder.LineMetadata] = []) -> DiffPaneCodeTextView {
        let textView = DiffPaneCodeTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120), textContainer: NSTextContainer())
        textView.textContainerInset = NSSize(width: 10, height: 8)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        textView.lineMetadata = metadata
        textView.lineTones = metadata.map { lineTone(for: $0.kind) }
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        return textView
    }

    private func lineTone(for kind: DiffDisplayRow.Kind) -> DiffPaneLineTone {
        switch kind {
        case .add:
            return .add
        case .delete:
            return .delete
        case .collapsed, .expandableContext:
            return .collapsed
        case .context, .expandedContext, .replacement:
            return .context
        }
    }

    private func addToWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        return window
    }

    private func mouseMovedEvent(in textView: DiffPaneCodeTextView, at point: NSPoint, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: textView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
    }

    private func firstGlyphRect(in textView: DiffPaneCodeTextView, range: NSRange) throws -> NSRect {
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        return rect.offsetBy(dx: textView.textContainerInset.width, dy: textView.textContainerInset.height)
    }

    private func makeTemporaryDiffRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-diff-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init"], cwd: root)
        try runGit(["config", "user.name", "Alas Tests"], cwd: root)
        try runGit(["config", "user.email", "alas-tests@example.com"], cwd: root)
        try runGit(["config", "commit.gpgsign", "false"], cwd: root)
        let sourceDir = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let file = sourceDir.appendingPathComponent("App.swift")
        try "let a = 1\nlet b = 2\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "Sources/App.swift"], cwd: root)
        try runGit(["commit", "-m", "Initial"], cwd: root)
        try "let a = 1\nlet b = 3\n".write(to: file, atomically: true, encoding: .utf8)
        return root
    }

    private func runGit(_ arguments: [String], cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = cwd
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "git failed"
            throw NSError(domain: "DiffPaneViewTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private func reviewDraftComment(
        id: String,
        fileID: DiffReviewFileID,
        path: String = "Sources/App.swift",
        startLine: Int = 2
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .localChanges(
                worktreeID: "worktree",
                worktreePath: URL(fileURLWithPath: "/tmp/worktree"),
                scope: .unstaged
            ),
            fileID: fileID,
            path: path,
            originalPath: nil,
            side: .new,
            startLine: startLine,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Draft body",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @MainActor
    private func waitForRenderPass(
        controller: NSHostingController<some View>,
        until predicate: () -> Bool
    ) async throws {
        for _ in 0..<50 {
            controller.view.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "DiffPaneViewTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for render pass",
        ])
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private struct ColorComponents {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        func isClose(to other: ColorComponents, tolerance: Double = 0.001) -> Bool {
            abs(red - other.red) <= tolerance
                && abs(green - other.green) <= tolerance
                && abs(blue - other.blue) <= tolerance
                && abs(alpha - other.alpha) <= tolerance
        }
    }

    private func colorComponents(_ color: NSColor) -> ColorComponents {
        let normalized = color.usingColorSpace(.sRGB) ?? color
        return ColorComponents(
            red: Double(normalized.redComponent),
            green: Double(normalized.greenComponent),
            blue: Double(normalized.blueComponent),
            alpha: Double(normalized.alphaComponent)
        )
    }

    private final class ConstraintInvalidationCountingView: NSView {
        var constraintInvalidationCount = 0

        override var needsUpdateConstraints: Bool {
            didSet {
                guard needsUpdateConstraints else { return }
                constraintInvalidationCount += 1
            }
        }
    }

    private final class LayoutMeasurementCounter: @unchecked Sendable {
        var measurementCount = 0
        var widthProposals: [CGFloat?] = []
    }

    private struct LayoutMeasurementProbe: Layout {
        let counter: LayoutMeasurementCounter

        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) -> CGSize {
            counter.measurementCount += 1
            counter.widthProposals.append(proposal.width)
            return CGSize(width: proposal.width ?? 100, height: 20)
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) {}
    }

    private struct FrameProbe: NSViewRepresentable {
        let identifier: String

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            view.setAccessibilityIdentifier(identifier)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            nsView.setAccessibilityIdentifier(identifier)
        }
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }

    private func selectReviewLine(selectionIndex: Int, in view: NSView) throws {
        let selectableRows = visibleReviewRulers(in: view).flatMap { ruler -> [(ruler: DiffPaneLineNumberRulerView, row: Int)] in
            guard let textView = ruler.scrollView?.documentView as? DiffPaneCodeTextView else { return [] }
            return (0..<200).compactMap { row in
                textView.reviewLineAnchor(atRow: row).map { _ in (ruler, row) }
            }
        }
        let selection = try #require(selectableRows.dropFirst(selectionIndex).first)
        selection.ruler.invokeReviewLineSelectionForTesting(row: selection.row)
    }

    private func visibleReviewRulers(in view: NSView) -> [DiffPaneLineNumberRulerView] {
        allSubviews(of: view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .compactMap { $0.verticalRulerView as? DiffPaneLineNumberRulerView }
            .filter(\.allowsReviewLineSelection)
    }

    private func draftComposerTextView(in view: NSView) -> NSTextView? {
        allSubviews(of: view).compactMap { subview -> NSTextView? in
            guard let textView = subview as? NSTextView,
                  !(textView is DiffPaneCodeTextView)
            else { return nil }
            return textView
        }.first
    }

    private func visibleCodeTextViews(in view: NSView) -> [DiffPaneCodeTextView] {
        allSubviews(of: view)
            .compactMap { $0 as? DiffPaneTextScrollView }
            .filter(isEffectivelyVisible)
            .sorted { $0.frame.minX < $1.frame.minX }
            .compactMap { $0.documentView as? DiffPaneCodeTextView }
    }

    private func isEffectivelyVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden {
                return false
            }
            current = candidate.superview
        }
        return true
    }
}

@MainActor
private final class DiffTabViewFocusRetainer {
    private static var retainedObjects: [AnyObject] = []

    static func retain(_ objects: AnyObject...) {
        retainedObjects.append(contentsOf: objects)
    }
}

private final class DiffTabViewFocusSinkView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
