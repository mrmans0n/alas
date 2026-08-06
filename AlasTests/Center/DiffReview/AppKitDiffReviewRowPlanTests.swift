import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppKitDiffReviewRowPlanTests {
    @Test func textRowsHaveStableUniqueIDsAndTheirOwningFile() {
        let input = AppKitDiffReviewRowInput(file: textFile(), state: AppKitDiffReviewFileState(), theme: theme)

        let first = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let second = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])

        #expect(first.corePlan.rows.map(\.id) == second.corePlan.rows.map(\.id))
        #expect(Set(first.corePlan.rows.map(\.id)).count == first.corePlan.rows.count)
        #expect(first.corePlan.rows.allSatisfy { $0.ownerID == input.file.id.rawValue })
        #expect(first.corePlan.rows.contains { $0.id.hasSuffix(":header") })
        #expect(first.corePlan.rows.contains { $0.id.contains(":group:") })
        #expect(first.corePlan.rows.contains { $0.id.hasSuffix(":spacing") })
    }

    @Test func deferredFilesMapReviewTargetsToTheirPlaceholder() {
        let feedback = feedback(line: nil)
        let input = AppKitDiffReviewRowInput(
            file: textFile(), inlineFeedback: [feedback], state: AppKitDiffReviewFileState(), theme: theme,
            automaticallyRendersDiff: false
        )

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let placeholderID = "file:\(input.file.id.rawValue):placeholder"

        #expect(plan.corePlan.rows.map { $0.id } == ["file:\(input.file.id.rawValue):header", placeholderID])
        #expect(plan.placeholderByFileID[input.file.id] == placeholderID)
        #expect(plan.fallbackByTargetID[AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: input.file.id))] == placeholderID)
    }

    @Test func imageFilesEmitAccessoriesAndImageWithoutTextHunksOrSpacing() {
        let file = imageFile()
        let feedback = feedback(path: file.summary.path, line: nil)
        let input = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [feedback], state: AppKitDiffReviewFileState(), theme: theme
        )

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let ids = plan.corePlan.rows.map { $0.id }

        #expect(ids == [
            AppKitDiffReviewRowID.header(fileID: file.id),
            AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: file.id)),
            AppKitDiffReviewRowID.image(fileID: file.id),
        ])
        #expect(!ids.contains { $0.contains(":group:") || $0.contains(":segment:") })
    }

    @Test func unavailableFilesEmitHeaderAndPlaceholder() {
        let file = placeholderFile()
        let input = AppKitDiffReviewRowInput(file: file, state: AppKitDiffReviewFileState(), theme: theme)

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])

        #expect(plan.corePlan.rows.map { $0.id } == [
            AppKitDiffReviewRowID.header(fileID: file.id),
            AppKitDiffReviewRowID.placeholder(fileID: file.id),
        ])
    }

    @Test func aggregateBudgetDefersLaterFilesBeforeBuildingTheirContext() {
        let first = textFile(path: "Sources/First.swift")
        let second = textFile(path: "Sources/Second.swift")
        let firstState = AppKitDiffReviewFileState()
        let secondState = AppKitDiffReviewFileState()

        let plan = AppKitDiffReviewRowPlanBuilder.build(
            inputs: [
                .init(file: first, state: firstState, theme: theme),
                .init(file: second, state: secondState, theme: theme),
            ],
            maxAutomaticallyRenderedRows: DiffReviewRenderBudget.renderedRowCount(of: first.displayModel!)
        )

        #expect(plan.placeholderByFileID[first.id] == nil)
        #expect(plan.placeholderByFileID[second.id] == AppKitDiffReviewRowID.placeholder(fileID: second.id))
        #expect(secondState.renderContextCache.missCountForTests == 0)
    }

    @Test func renderedTargetsAreDirectRowsAndComposerIsPinned() throws {
        let file = textFile()
        let feedback = feedback(line: 1)
        let draft = draftComment(fileID: file.id)
        let state = AppKitDiffReviewFileState()
        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: file.summary.path, side: .new, line: 1, rowIndex: 1, selectedText: "let new = 1"
        )
        let input = AppKitDiffReviewRowInput(
            file: file, inlineFeedback: [feedback], draftComments: [draft], state: state, theme: theme
        )

        let plan = AppKitDiffReviewRowPlanBuilder.build(inputs: [input])
        let feedbackID = AppKitDiffReviewRowID.inlineFeedback(.targetID(feedbackID: feedback.id, fileID: file.id))
        let draftID = AppKitDiffReviewRowID.draftComment(.targetID(commentID: draft.id, fileID: file.id))
        let composer = try #require(plan.corePlan.rows.first { $0.id.contains(":composer:") })

        #expect(plan.fallbackByTargetID[feedbackID] == feedbackID)
        #expect(plan.fallbackByTargetID[draftID] == draftID)
        #expect(plan.corePlan.rows.first { $0.id == draftID }?.retention == .recyclable)
        #expect(composer.retention == .pinned)
        #expect(plan.corePlan.rows.contains { $0.id.contains(":segment:") })
    }

    @Test func accessorySegmentRowsTrackLSPContextInTheirEqualityToken() throws {
        let file = textFile()
        let state = AppKitDiffReviewFileState()
        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: file.summary.path, side: .new, line: 1, rowIndex: 1, selectedText: "let new = 1"
        )
        let lsp = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: []))
        let withLSP = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, state: state, theme: theme, lspContext: lspContext(lsp: lsp, relativePath: file.summary.path)),
        ])
        let withoutLSP = AppKitDiffReviewRowPlanBuilder.build(inputs: [
            .init(file: file, state: state, theme: theme),
        ])
        let withSegment = try #require(withLSP.corePlan.rows.first { $0.id.contains(":segment:") })
        let withoutSegment = try #require(withoutLSP.corePlan.rows.first { $0.id == withSegment.id })

        #expect(!withSegment.equalityToken.isEqual(to: withoutSegment.equalityToken))
    }

    @Test func rowInputContextExpansionAppliesStateAndNotifies() {
        let snapshot = DiffReviewFileContextSnapshot(
            old: .available(["let a = 0", "let old = 1", "let c = 2"]),
            new: .available(["let a = 0", "let new = 1", "let c = 2"])
        )
        let file = textFile(contextProvider: DiffReviewContextProvider { snapshot })
        let state = AppKitDiffReviewFileState()
        state.contextSnapshot = snapshot
        var activationCount = 0
        let input = AppKitDiffReviewRowInput(
            file: file,
            state: state,
            theme: theme,
            onContextExpansionActivated: { activationCount += 1 }
        )
        let key = DiffContextExpansionKey(groupID: file.displayModel!.groups[0].id, boundary: .below)

        input.loadContextAndExpand(key, mode: .chunk(size: 1), edge: nil)

        #expect(activationCount == 1)
        #expect(state.contextExpansion.expandedLineCount(for: key) == 1)
    }

    private var theme: Theme { try! ThemeStore().current }

    private func textFile(
        path: String = "Sources/Example.swift",
        contextProvider: DiffReviewContextProvider? = nil
    ) -> DiffReviewFileSectionModel {
        let diff = ParsedDiff(hunks: [
            .init(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [
                .init(kind: .delete, text: "let old = 1", oldNumber: 1, newNumber: nil),
                .init(kind: .add, text: "let new = 1", oldNumber: nil, newNumber: 1),
            ]),
        ])
        let summary = DiffReviewFileSummary(
            path: path, namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 1, deletions: 1, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: diff,
            displayModel: DiffDisplayModelBuilder.build(diff: diff, filePath: summary.path),
            placeholderMessage: nil, openFile: nil, contextProvider: contextProvider
        )
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

    private func imageFile() -> DiffReviewFileSectionModel {
        let summary = DiffReviewFileSummary(
            path: "Assets/logo.png", namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 1, deletions: 1, isRenderable: true
        )
        return DiffReviewFileSectionModel(
            summary: summary, parsedDiff: nil, displayModel: nil, placeholderMessage: nil,
            openFile: nil, contextProvider: nil,
            imageProvider: .init(
                id: .init(
                    source: .commit, repository: "/repo", beforeRevision: "old", afterRevision: "new",
                    beforePath: summary.path, afterPath: summary.path
                ),
                load: { fatalError("The row-plan builder must not load image data") }
            )
        )
    }

    private func placeholderFile() -> DiffReviewFileSectionModel {
        let summary = DiffReviewFileSummary(
            path: "Assets/data.bin", namespace: "review", groupID: nil, groupTitle: nil,
            status: .modified, additions: 0, deletions: 0, isRenderable: false
        )
        return .init(
            summary: summary, parsedDiff: nil, displayModel: nil,
            placeholderMessage: "Binary file", openFile: nil, contextProvider: nil
        )
    }

    private func feedback(path: String = "Sources/Example.swift", line: Int?) -> DiffReviewInlineFeedback {
        .init(
            id: "feedback", providerName: "Provider", author: nil, bodyPreview: "Needs work",
            status: .actionable, providerURL: nil,
            anchor: .init(path: path, line: line, side: line == nil ? .unknown : .new),
            evidenceItemID: "evidence"
        )
    }

    private func draftComment(fileID: DiffReviewFileID) -> ReviewDraftComment {
        .init(
            id: "draft", sessionID: .commit(worktreeID: "wt", repositoryPath: URL(fileURLWithPath: "/repo"), sha: "abc"),
            fileID: fileID, path: fileID.path, originalPath: nil, side: .new,
            startLine: 1, endLine: nil, selectedText: "let new = 1", bodyMarkdown: "Please revisit.",
            state: .active, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2)
        )
    }
}
