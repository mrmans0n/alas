import Combine
import SwiftUI

@MainActor
final class AppKitDiffReviewPresentationStore: ObservableObject {
    private var states: [DiffReviewFileID: AppKitDiffReviewFileState] = [:]

    func state(for file: DiffReviewFileSectionModel) -> AppKitDiffReviewFileState {
        if let state = states[file.id] { return state }
        let state = AppKitDiffReviewFileState()
        states[file.id] = state
        return state
    }

    func prune(keeping fileIDs: Set<DiffReviewFileID>) {
        states = states.filter { fileIDs.contains($0.key) }
    }
}

@MainActor
final class AppKitDiffReviewFileState: ObservableObject {
    let copyFeedback = CopyFeedbackState()
    let renderContextCache = DiffReviewRenderContextCache()
    let actionRelay = AppKitDiffReviewActionRelay()
    @Published var pendingDraftAnchor: DiffReviewLineAnchor?
    @Published var pendingDraftBody = ""
    @Published var draftComposerFocusRequestGeneration = 0
    @Published var expandedCollapsedRowIDs: Set<String> = []
    @Published var contextSnapshot: DiffReviewFileContextSnapshot?
    @Published var contextExpansion = DiffContextExpansionState()
    @Published var contextLoadTask: Task<Void, Never>?
    @Published var contextLoadFileID: DiffReviewFileID?
    @Published var contextLoadSignature: DiffReviewContextStateSignature?
    @Published var contextLoadGeneration = 0
    @Published var contextLoadError: String?
    @Published var pendingContextExpansions: [PendingContextExpansion] = []
    @Published var imageState = DiffReviewImageState()
    @Published var hoveredInlineFeedbackID: String?
    @Published var hoveredDraftCommentID: String?
    @Published var activeThreadID: String?
    @Published var showFullDiffOverride = false
    @Published var isDraftComposerFocused = false

    private var fileID: DiffReviewFileID?
    private var contextSignature: DiffReviewContextStateSignature?
    private var renderBudgetSignal: Int?

    func synchronize(file: DiffReviewFileSectionModel, contextSignature: DiffReviewContextStateSignature) {
        if fileID != file.id {
            resetForFileIdentityChange()
            fileID = file.id
        }
        if self.contextSignature != nil, self.contextSignature != contextSignature {
            resetContextState()
        }
        self.contextSignature = contextSignature
    }

    func synchronizeRenderBudget(resetSignal: Int?) {
        if renderBudgetSignal != nil, renderBudgetSignal != resetSignal {
            resetForRenderBudgetChange()
        }
        renderBudgetSignal = resetSignal
    }

    func resetForFileIdentityChange() {
        pendingDraftAnchor = nil
        pendingDraftBody = ""
        draftComposerFocusRequestGeneration = 0
        expandedCollapsedRowIDs = []
        hoveredInlineFeedbackID = nil
        hoveredDraftCommentID = nil
        activeThreadID = nil
        showFullDiffOverride = false
        isDraftComposerFocused = false
        imageState.clear()
        resetContextState()
    }

    func resetForRenderBudgetChange() {
        showFullDiffOverride = false
    }

    func resetContextState() {
        contextLoadTask?.cancel()
        contextLoadGeneration &+= 1
        contextSnapshot = nil
        contextExpansion = DiffContextExpansionState()
        contextLoadTask = nil
        contextLoadFileID = nil
        contextLoadSignature = nil
        contextLoadError = nil
        pendingContextExpansions = []
    }

    func beginContextLoad(fileID: DiffReviewFileID, signature: DiffReviewContextStateSignature) -> Int {
        contextLoadGeneration &+= 1
        contextLoadFileID = fileID
        contextLoadSignature = signature
        return contextLoadGeneration
    }

    func acceptsContextResult(fileID: DiffReviewFileID, generation: Int) -> Bool {
        contextLoadGeneration == generation && contextLoadFileID == fileID
    }
}

@MainActor
final class AppKitDiffReviewActionRelay {
    private var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
    private var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }
    private var draftCommentActions = ReviewDraftCommentActions()
    private var onSelectDraftComment: (ReviewDraftComment) -> Void = { _ in }
    private var onSaveDraftComment: (DiffReviewLineAnchor, String) -> Void = { _, _ in }
    private var onContextExpansionActivated: () -> Void = {}
    private var onReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }
    private var onResolve: (DiffInlineCommentThread) -> Void = { _ in }
    private var onUnresolve: (DiffInlineCommentThread) -> Void = { _ in }
    private var onEdit: (DiffInlineCommentThread, DiffInlineComment, String) -> Void = { _, _, _ in }
    private var onDelete: (DiffInlineCommentThread, DiffInlineComment) -> Void = { _, _ in }
    private var onStageReply: (DiffInlineCommentThread, String) -> Void = { _, _ in }

    func update(
        inlineFeedbackActions: DiffReviewInlineFeedbackActions,
        onSelectInlineFeedback: @escaping (DiffReviewInlineFeedback) -> Void,
        draftCommentActions: ReviewDraftCommentActions,
        onSelectDraftComment: @escaping (ReviewDraftComment) -> Void,
        onSaveDraftComment: @escaping (DiffReviewLineAnchor, String) -> Void,
        onContextExpansionActivated: @escaping () -> Void,
        onReply: @escaping (DiffInlineCommentThread, String) -> Void,
        onResolve: @escaping (DiffInlineCommentThread) -> Void,
        onUnresolve: @escaping (DiffInlineCommentThread) -> Void,
        onEdit: @escaping (DiffInlineCommentThread, DiffInlineComment, String) -> Void,
        onDelete: @escaping (DiffInlineCommentThread, DiffInlineComment) -> Void,
        onStageReply: @escaping (DiffInlineCommentThread, String) -> Void
    ) {
        self.inlineFeedbackActions = inlineFeedbackActions
        self.onSelectInlineFeedback = onSelectInlineFeedback
        self.draftCommentActions = draftCommentActions
        self.onSelectDraftComment = onSelectDraftComment
        self.onSaveDraftComment = onSaveDraftComment
        self.onContextExpansionActivated = onContextExpansionActivated
        self.onReply = onReply
        self.onResolve = onResolve
        self.onUnresolve = onUnresolve
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onStageReply = onStageReply
    }

    func update(onSelectInlineFeedback: @escaping (DiffReviewInlineFeedback) -> Void) {
        self.onSelectInlineFeedback = onSelectInlineFeedback
    }

    func selectInlineFeedback(_ item: DiffReviewInlineFeedback) {
        onSelectInlineFeedback(item)
    }

    func saveDraftComment(_ anchor: DiffReviewLineAnchor, body: String) { onSaveDraftComment(anchor, body) }
    func contextExpansionActivated() { onContextExpansionActivated() }
}
