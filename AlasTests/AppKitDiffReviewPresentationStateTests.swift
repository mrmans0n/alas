import Combine
import Testing
@testable import Alas

@MainActor
struct AppKitDiffReviewPresentationStateTests {
    @Test func storeRetainsStateForTheSameFile() {
        let store = AppKitDiffReviewPresentationStore()
        let file = fileModel(path: "Sources/Retained.swift")
        let state = store.state(for: file)
        state.pendingDraftBody = "keep me"

        #expect(store.state(for: file) === state)
        store.prune(keeping: [file.id])
        #expect(store.state(for: file).pendingDraftBody == "keep me")
    }

    @Test func storePrunesStateForAbsentFiles() {
        let store = AppKitDiffReviewPresentationStore()
        let retained = fileModel(path: "Sources/Retained.swift")
        let removed = fileModel(path: "Sources/Removed.swift")
        let removedState = store.state(for: removed)

        store.prune(keeping: [retained.id])

        #expect(store.state(for: removed) !== removedState)
    }

    @Test func retainedStateKeepsDraftAndExpandedContextAcrossUnmount() {
        let store = AppKitDiffReviewPresentationStore()
        let file = fileModel()
        let state = store.state(for: file)
        state.pendingDraftBody = "keep me"
        state.expandedCollapsedRowIDs = ["hunk:1"]

        let remounted = store.state(for: file)

        #expect(remounted.pendingDraftBody == "keep me")
        #expect(remounted.expandedCollapsedRowIDs == ["hunk:1"])
    }

    @Test func fileAndHunkPresentationShareCollapsedContextState() {
        let state = AppKitDiffReviewFileState()

        state.hunkPresentationState.setExpandedCollapsedRowIDs(["hunk:1"])
        #expect(state.expandedCollapsedRowIDs == ["hunk:1"])

        state.expandedCollapsedRowIDs = ["hunk:2"]
        #expect(state.hunkPresentationState.expandedCollapsedRowIDs == ["hunk:2"])
    }

    @Test func renderBudgetResetClearsFullDiffOverride() {
        let state = AppKitDiffReviewFileState()
        state.showFullDiffOverride = true

        state.resetForRenderBudgetChange()

        #expect(!state.showFullDiffOverride)
    }

    @Test func changedContextSignatureResetsContextState() {
        let state = AppKitDiffReviewFileState()
        let file = fileModel()
        state.contextLoadError = "old error"
        state.synchronize(file: file, contextSignature: signature(file: file, providerID: "first"))
        state.contextLoadError = "new error"

        state.synchronize(file: file, contextSignature: signature(file: file, providerID: "second"))

        #expect(state.contextLoadError == nil)
    }

    @Test func changedStructuralSignatureClearsPendingDraft() {
        let state = AppKitDiffReviewFileState()
        let file = fileModel()
        state.synchronize(file: file, contextSignature: signature(file: file, providerID: "first"))
        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: "Sources/File.swift", side: .new, line: 1, rowIndex: 0, selectedText: "old line"
        )
        state.pendingDraftBody = "stale draft"

        state.synchronize(file: file, contextSignature: signature(file: file, providerID: "second"))

        #expect(state.pendingDraftAnchor == nil)
        #expect(state.pendingDraftBody.isEmpty)
    }

    @Test func staleContextGenerationCannotPublish() {
        let state = AppKitDiffReviewFileState()
        let file = fileModel()
        state.synchronize(file: file, contextSignature: signature(file: file, providerID: "provider"))
        let oldGeneration = state.beginContextLoad(fileID: file.id, signature: signature(file: file, providerID: "provider"))
        state.resetContextState()

        #expect(!state.acceptsContextResult(fileID: file.id, generation: oldGeneration))
    }

    @Test func actionRelayUsesLatestCallbackForExistingRow() {
        let relay = AppKitDiffReviewActionRelay()
        let item = DiffReviewInlineFeedback(
            id: "feedback",
            providerName: "GitHub",
            author: nil,
            bodyPreview: "Note",
            status: .pending,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/File.swift", line: 1, side: .new),
            evidenceItemID: "evidence"
        )
        var calls: [String] = []
        let existingRowAction = { relay.selectInlineFeedback(item) }
        relay.update(onSelectInlineFeedback: { _ in calls.append("first") })
        relay.update(onSelectInlineFeedback: { _ in calls.append("second") })

        existingRowAction()

        #expect(calls == ["second"])
    }

    @Test func actionRelayForwardsLatestActionStructForAnExistingRow() {
        let relay = AppKitDiffReviewActionRelay()
        let item = inlineFeedbackItem()
        let file = fileModel().summary
        let rowActions = relay.inlineFeedbackActionsForRow
        var calls: [String] = []

        relay.update(inlineFeedbackActions: DiffReviewInlineFeedbackActions(
            copyContext: { _, _ in calls.append("first") }
        ))
        relay.update(inlineFeedbackActions: DiffReviewInlineFeedbackActions(
            copyContext: { _, _ in calls.append("second") }
        ))

        rowActions.copyContext(item, file)

        #expect(calls == ["second"])
    }

    @Test func actionRelayForwardsLatestDraftActionStructForAnExistingRow() {
        let relay = AppKitDiffReviewActionRelay()
        let rowActions = relay.draftCommentActionsForRow
        var calls: [String] = []

        relay.update(draftCommentActions: ReviewDraftCommentActions(
            publishReview: { calls.append("first") }
        ))
        relay.update(draftCommentActions: ReviewDraftCommentActions(
            publishReview: { calls.append("second") }
        ))

        rowActions.publishReview()

        #expect(calls == ["second"])
    }

    @Test func presentationStoreIgnoresComposerTypingButForwardsHoverAndStructuralChanges() {
        let store = AppKitDiffReviewPresentationStore()
        let state = store.state(for: fileModel())
        var changes = 0
        let cancellable = store.objectWillChange.sink { changes += 1 }

        state.pendingDraftBody = "a"
        state.hoveredInlineFeedbackID = "feedback"
        #expect(changes == 1)
        state.hoveredDraftCommentID = "draft"
        #expect(changes == 2)

        state.pendingDraftAnchor = DiffReviewLineAnchor(
            path: "Sources/File.swift", side: .new, line: 1, rowIndex: 0, selectedText: "line"
        )
        #expect(changes == 3)
        _ = cancellable
    }

    @Test func presentationStoreForwardsCopyFeedbackChanges() {
        let store = AppKitDiffReviewPresentationStore()
        let state = store.state(for: fileModel())
        var changes = 0
        let cancellable = store.objectWillChange.sink { changes += 1 }

        state.copyFeedback.show("Copied prompt")

        #expect(changes == 1)
        _ = cancellable
    }

    @Test func actionRelayUsesLatestHunkCallbackForAnExistingRow() throws {
        let relay = AppKitDiffReviewActionRelay()
        let hunk = ParsedDiff.Hunk(header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: [])
        var calls: [String] = []
        relay.update(stagedMutationActions: .init(
            unstageHunk: { _ in calls.append("first") }, isHunkUnstageEnabled: { _ in true }
        ))
        relay.update(stagedMutationActions: .init(
            unstageHunk: { _ in calls.append("second") }, isHunkUnstageEnabled: { _ in true }
        ))

        let latestActions = relay.hunkActions(for: hunk)
        let dropFromCommit = try #require(latestActions.dropFromCommit)
        dropFromCommit()
        #expect(calls == ["second"])
    }

    private func inlineFeedbackItem() -> DiffReviewInlineFeedback {
        DiffReviewInlineFeedback(
            id: "feedback",
            providerName: "GitHub",
            author: nil,
            bodyPreview: "Note",
            status: .pending,
            providerURL: nil,
            anchor: DiffReviewInlineFeedbackAnchor(path: "Sources/File.swift", line: 1, side: .new),
            evidenceItemID: "evidence"
        )
    }

    private func fileModel(path: String = "Sources/File.swift") -> DiffReviewFileSectionModel {
        DiffReviewFileSectionModel(
            summary: DiffReviewFileSummary(
                path: path,
                namespace: "working-tree",
                groupID: nil,
                groupTitle: nil,
                status: .modified,
                additions: 1,
                deletions: 0,
                isRenderable: true
            ),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: nil,
            openFile: nil,
            contextProvider: nil
        )
    }

    private func signature(file: DiffReviewFileSectionModel, providerID: String) -> DiffReviewContextStateSignature {
        DiffReviewContextStateSignature(
            fileID: file.id.rawValue,
            providerID: providerID,
            structuralHash: nil
        )
    }
}
