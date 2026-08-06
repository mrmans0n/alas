import SwiftUI
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct DiffPaneRowPlanTests {
    @Test func rebuildKeepsHunkIDsAndTokensStableWhenInputsAreUnchanged() {
        let input = input()
        let state = DiffPanePresentationState()

        let first = DiffPaneRowPlanBuilder.build(input: input, state: state)
        let second = DiffPaneRowPlanBuilder.build(input: input, state: state)

        #expect(first.rows.map(\.id) == second.rows.map(\.id))
        #expect(first.rows.count == 2)
        #expect(first.rows[0].id != first.rows[1].id)
        #expect(first.rows[0].equalityToken.isEqual(to: second.rows[0].equalityToken))
    }

    @Test func tokenChangesForEveryPlainRenderingInput() {
        let base = input()
        let state = DiffPanePresentationState()
        let baseToken = DiffPaneRowPlanBuilder.build(input: base, state: state).rows[0].equalityToken

        let variants = [
            input(layoutMode: .stacked),
            input(wrapLines: true),
            input(showWhitespace: true),
            input(codeFontFamily: "Menlo"),
            input(codeFontSize: 15),
            input(theme: accentedTheme()),
            input(model: changedModel()),
        ]

        for variant in variants {
            let token = DiffPaneRowPlanBuilder.build(input: variant, state: state).rows[0].equalityToken
            #expect(!baseToken.isEqual(to: token))
        }
    }

    @Test func actionClosureIdentityDoesNotChangeToken() {
        let state = DiffPanePresentationState()
        let first = DiffPaneRowPlanBuilder.build(input: input(actions: { _ in .init(stage: {}) }), state: state)
        let second = DiffPaneRowPlanBuilder.build(input: input(actions: { _ in .init(stage: {}) }), state: state)

        #expect(first.rows[0].equalityToken.isEqual(to: second.rows[0].equalityToken))
    }

    @Test func tokenChangesWhenLSPContextChanges() {
        let state = DiffPanePresentationState()
        let baseToken = DiffPaneRowPlanBuilder.build(input: input(), state: state).rows[0].equalityToken
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let lspToken = DiffPaneRowPlanBuilder.build(
            input: input(lspContext: lspContext(lsp: lsp, relativePath: "Sources/Example.swift")),
            state: state
        ).rows[0].equalityToken

        #expect(!baseToken.isEqual(to: lspToken))
    }

    @Test func equalTokenRowsInvokeTheLatestHunkHandler() throws {
        let state = DiffPanePresentationState()
        var calls: [String] = []
        let first = DiffPaneRowPlanBuilder.build(
            input: input(actions: { _ in .init(stage: { calls.append("first") }) }), state: state
        )
        let second = DiffPaneRowPlanBuilder.build(
            input: input(actions: { _ in .init(stage: { calls.append("second") }) }), state: state
        )

        #expect(first.rows[0].equalityToken.isEqual(to: second.rows[0].equalityToken))
        let latestActions = state.actionRelay.hunkActions(for: model().groups[0].sourceHunk)
        let stage = try #require(latestActions.stage)
        stage()
        #expect(calls == ["second"])
    }

    @Test func hunkRowIsPinnedWhileContainedThreadEditorIsActive() throws {
        let thread = DiffInlineCommentThread(
            id: "thread", filePath: "Sources/Example.swift", newLine: 1, isOldSide: false,
            isResolved: false, isOutdated: false, comments: []
        )
        let state = DiffPanePresentationState()
        let resting = try #require(DiffPaneRowPlanBuilder.build(input: input(threads: [thread]), state: state).rows.first)

        state.setThreadActive(thread.id, active: true)
        let active = try #require(DiffPaneRowPlanBuilder.build(input: input(threads: [thread]), state: state).rows.first)

        #expect(resting.retention == .recyclable)
        #expect(active.retention == .pinned)
    }

    @Test func expandedContextUpdatesTheRowEstimate() throws {
        let input = input(model: collapsibleModel())
        let state = DiffPanePresentationState()
        let group = try #require(input.model.groups.first)

        state.toggleCollapsedContext(in: group)
        let expanded = try #require(DiffPaneRowPlanBuilder.build(input: input, state: state).rows.first)
        let expected = DiffPaneStaticHeightEstimator.estimatedHeight(
            for: .init(filePath: input.model.filePath, groups: [group]),
            layoutMode: input.layoutMode,
            expandedCollapsedRowIDs: state.expandedCollapsedRowIDs,
            codeFont: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize),
            headerFont: CenterTypography.resolveCodeFont(family: input.codeFontFamily, size: input.codeFontSize - 1),
            wrapLines: input.wrapLines,
            showWhitespace: input.showWhitespace,
            fusionStates: [DiffPaneHunkFusionResolver.states(for: input.model.groups)[0]]
        )

        #expect(expanded.estimatedHeight == expected)
    }

    private func input(
        model: DiffDisplayModel? = nil,
        layoutMode: DiffLayoutMode = .split,
        wrapLines: Bool = false,
        showWhitespace: Bool = false,
        codeFontFamily: String = "SF Mono",
        codeFontSize: CGFloat = 13,
        theme: Theme? = nil,
        lspContext: DiffPaneLSPContext? = nil,
        threads: [DiffInlineCommentThread] = [],
        actions: @escaping (ParsedDiff.Hunk) -> DiffPaneHunkActions = { _ in .init() }
    ) -> DiffPaneRowPlanInput {
        DiffPaneRowPlanInput(
            model: model ?? self.model(),
            fileExtension: "swift",
            layoutMode: layoutMode,
            wrapLines: wrapLines,
            showWhitespace: showWhitespace,
            codeFontFamily: codeFontFamily,
            codeFontSize: codeFontSize,
            theme: theme ?? (try! ThemeStore().current),
            lspContext: lspContext,
            threads: threads,
            hunkActions: actions
        )
    }

    private func accentedTheme() -> Theme {
        var theme = try! ThemeStore().current
        theme.accentOverrideHex = "#ff00ff"
        return theme
    }

    private func lspContext(lsp: WorkspaceLSPManager, relativePath: String) -> DiffPaneLSPContext {
        DiffPaneLSPContext(
            worktreeId: "wt",
            worktreeRoot: URL(fileURLWithPath: "/tmp/repo"),
            relativePath: relativePath,
            language: "swift",
            lsp: lsp,
            openTarget: { _, _, _ in }
        )
    }

    private func model() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                .init(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
                    .init(kind: .delete, text: "let old = 1", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "let new = 2", oldNumber: nil, newNumber: 1),
                ]),
                .init(header: "@@ -10 +10 @@", oldStart: 10, newStart: 10, lines: [
                    .init(kind: .context, text: "let value = 3", oldNumber: 10, newNumber: 10),
                ]),
            ]),
            filePath: "Sources/Example.swift"
        )
    }

    private func changedModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                .init(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
                    .init(kind: .delete, text: "let old = 1", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "let changed = 2", oldNumber: nil, newNumber: 1),
                ]),
                .init(header: "@@ -10 +10 @@", oldStart: 10, newStart: 10, lines: [
                    .init(kind: .context, text: "let value = 3", oldNumber: 10, newNumber: 10),
                ]),
            ]),
            filePath: "Sources/Example.swift"
        )
    }

    private func collapsibleModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(
            diff: ParsedDiff(hunks: [
                .init(
                    header: "@@ -1,15 +1,15 @@",
                    oldStart: 1,
                    newStart: 1,
                    lines: (1...15).map {
                        .init(kind: .context, text: "let value\($0) = \($0)", oldNumber: $0, newNumber: $0)
                    }
                ),
            ]),
            filePath: "Sources/Example.swift"
        )
    }
}
