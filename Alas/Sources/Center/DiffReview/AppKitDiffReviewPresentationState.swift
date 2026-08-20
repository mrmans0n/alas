import Combine
import SwiftUI

@MainActor
final class AppKitDiffReviewPresentationStore: ObservableObject {
    private var states: [DiffReviewFileID: AppKitDiffReviewFileState] = [:]
    private var stateCancellables: [DiffReviewFileID: AnyCancellable] = [:]

    func state(for file: DiffReviewFileSectionModel) -> AppKitDiffReviewFileState {
        if let state = states[file.id] { return state }
        let state = AppKitDiffReviewFileState()
        states[file.id] = state
        stateCancellables[file.id] = state.structuralDidChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return state
    }

    func prune(keeping fileIDs: Set<DiffReviewFileID>) {
        states = states.filter { fileIDs.contains($0.key) }
        stateCancellables = stateCancellables.filter { fileIDs.contains($0.key) }
    }
}

@MainActor
final class AppKitDiffReviewFileState: ObservableObject {
    let structuralDidChange = PassthroughSubject<Void, Never>()
    let copyFeedback = CopyFeedbackState()
    let renderContextCache = DiffReviewRenderContextCache()
    let actionRelay = AppKitDiffReviewActionRelay()
    let hunkPresentationState = DiffPanePresentationState()
    @Published var pendingDraftAnchor: DiffReviewLineAnchor? { didSet { structuralDidChange.send() } }
    @Published var pendingDraftBody = ""
    @Published var draftComposerFocusRequestGeneration = 0 { didSet { structuralDidChange.send() } }
    @Published var quoteInsertionGeneration = 0 { didSet { structuralDidChange.send() } }
    var expandedCollapsedRowIDs: Set<String> {
        get { hunkPresentationState.expandedCollapsedRowIDs }
        set { hunkPresentationState.setExpandedCollapsedRowIDs(newValue) }
    }
    @Published var contextSnapshot: DiffReviewFileContextSnapshot? { didSet { structuralDidChange.send() } }
    @Published var contextExpansion = DiffContextExpansionState() { didSet { structuralDidChange.send() } }
    @Published var contextLoadTask: Task<Void, Never>?
    @Published var contextLoadFileID: DiffReviewFileID?
    @Published var contextLoadSignature: DiffReviewContextStateSignature?
    @Published var contextLoadGeneration = 0
    @Published var contextLoadError: String? { didSet { structuralDidChange.send() } }
    @Published var pendingContextExpansions: [PendingContextExpansion] = []
    @Published var imageState = DiffReviewImageState()
    @Published var hoveredInlineFeedbackID: String? { didSet { structuralDidChange.send() } }
    @Published var hoveredDraftCommentID: String? { didSet { structuralDidChange.send() } }
    @Published var activeInlineFeedbackEditorID: String? { didSet { structuralDidChange.send() } }
    @Published var activeDraftCommentEditorID: String? { didSet { structuralDidChange.send() } }
    @Published var activeThreadID: String? { didSet { structuralDidChange.send() } }
    @Published var inlineFeedbackReplyEditors: [String: DiffReviewInlineFeedbackReplyEditorState] = [:]
    @Published var draftCommentEditors: [String: ReviewDraftCommentEditorState] = [:]
    @Published var threadCommentEditors: [String: DiffInlineCommentCardEditorState] = [:]
    @Published var showFullDiffOverride = false { didSet { structuralDidChange.send() } }
    @Published var isDraftComposerFocused = false { didSet { structuralDidChange.send() } }

    private var fileID: DiffReviewFileID?
    private var contextSignature: DiffReviewContextStateSignature?
    private var renderBudgetSignal: Int?
    private var copyFeedbackCancellable: AnyCancellable?
    private var hunkPresentationCancellable: AnyCancellable?
    private var hunkActiveThreadCancellable: AnyCancellable?

    init() {
        copyFeedbackCancellable = copyFeedback.$message.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.structuralDidChange.send()
        }
        hunkPresentationCancellable = hunkPresentationState.$expandedCollapsedRowIDs.sink { [weak self] _ in
            self?.structuralDidChange.send()
        }
        hunkActiveThreadCancellable = hunkPresentationState.$activeThreadID.sink { [weak self] _ in
            self?.structuralDidChange.send()
        }
    }

    func synchronize(file: DiffReviewFileSectionModel, contextSignature: DiffReviewContextStateSignature) {
        if fileID != file.id {
            resetForFileIdentityChange()
            fileID = file.id
        }
        if self.contextSignature != nil, self.contextSignature != contextSignature {
            resetContextState()
            clearPendingDraft()
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
        clearPendingDraft()
        draftComposerFocusRequestGeneration = 0
        expandedCollapsedRowIDs = []
        hoveredInlineFeedbackID = nil
        hoveredDraftCommentID = nil
        activeInlineFeedbackEditorID = nil
        activeDraftCommentEditorID = nil
        activeThreadID = nil
        inlineFeedbackReplyEditors = [:]
        draftCommentEditors = [:]
        threadCommentEditors = [:]
        showFullDiffOverride = false
        isDraftComposerFocused = false
        imageState.clear()
        resetContextState()
    }

    func clearPendingDraft() {
        pendingDraftAnchor = nil
        pendingDraftBody = ""
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

    func bindingForInlineFeedbackReplyEditor(_ id: String) -> Binding<DiffReviewInlineFeedbackReplyEditorState> {
        Binding(
            get: { self.inlineFeedbackReplyEditors[id] ?? DiffReviewInlineFeedbackReplyEditorState() },
            set: { newValue in
                let previous = self.inlineFeedbackReplyEditors[id] ?? DiffReviewInlineFeedbackReplyEditorState()
                self.inlineFeedbackReplyEditors[id] = newValue
                if previous.isReplying != newValue.isReplying {
                    self.structuralDidChange.send()
                }
            }
        )
    }

    func bindingForDraftCommentEditor(_ id: String) -> Binding<ReviewDraftCommentEditorState> {
        Binding(
            get: { self.draftCommentEditors[id] ?? ReviewDraftCommentEditorState() },
            set: { newValue in
                let previous = self.draftCommentEditors[id] ?? ReviewDraftCommentEditorState()
                self.draftCommentEditors[id] = newValue
                if previous.isEditing != newValue.isEditing {
                    self.structuralDidChange.send()
                }
            }
        )
    }

    func bindingForThreadCommentEditor(_ id: String) -> Binding<DiffInlineCommentCardEditorState> {
        Binding(
            get: { self.threadCommentEditors[id] ?? DiffInlineCommentCardEditorState() },
            set: { newValue in
                let previous = self.threadCommentEditors[id] ?? DiffInlineCommentCardEditorState()
                self.threadCommentEditors[id] = newValue
                if previous.isComposerOpen != newValue.isComposerOpen
                    || previous.editingCommentID != newValue.editingCommentID {
                    self.structuralDidChange.send()
                }
            }
        )
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
    private var stagedMutationActions: DiffReviewStagedMutationActions?
    private var openFile: (() -> Void)?

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

    func update(inlineFeedbackActions: DiffReviewInlineFeedbackActions) {
        self.inlineFeedbackActions = inlineFeedbackActions
    }

    func update(draftCommentActions: ReviewDraftCommentActions) {
        self.draftCommentActions = draftCommentActions
    }

    func update(stagedMutationActions: DiffReviewStagedMutationActions?, openFile: (() -> Void)? = nil) {
        self.stagedMutationActions = stagedMutationActions
        self.openFile = openFile
    }

    func update(onContextExpansionActivated: @escaping () -> Void) {
        self.onContextExpansionActivated = onContextExpansionActivated
    }

    var inlineFeedbackActionsForRow: DiffReviewInlineFeedbackActions {
        DiffReviewInlineFeedbackActions(
            availability: { item, file in self.inlineFeedbackActions.availability(item, file) },
            openProvider: { item, file in self.inlineFeedbackActions.openProvider(item, file) },
            copyContext: { item, file in self.inlineFeedbackActions.copyContext(item, file) },
            sendToAgent: { item, file in self.inlineFeedbackActions.sendToAgent(item, file) },
            replyProvider: { item, file, body in self.inlineFeedbackActions.replyProvider(item, file, body) },
            resolveProvider: { item, file in self.inlineFeedbackActions.resolveProvider(item, file) },
            unresolveProvider: { item, file in self.inlineFeedbackActions.unresolveProvider(item, file) }
        )
    }

    var draftCommentActionsForRow: ReviewDraftCommentActions {
        ReviewDraftCommentActions(
            availability: { comment in self.draftCommentActions.availability(comment) },
            canPublishReview: { self.draftCommentActions.canPublishReview() },
            edit: { comment, body in self.draftCommentActions.edit(comment, body) },
            delete: { comment in self.draftCommentActions.delete(comment) },
            resolve: { comment in self.draftCommentActions.resolve(comment) },
            dismiss: { comment in self.draftCommentActions.dismiss(comment) },
            copyPrompt: { bundle in self.draftCommentActions.copyPrompt(bundle) },
            publishProvider: { comment in self.draftCommentActions.publishProvider(comment) },
            publishReview: { self.draftCommentActions.publishReview() },
            agent: { target in self.draftCommentActions.agent(target) },
            agentTargets: { self.draftCommentActions.agentTargets() },
            sendToAgent: { bundle, target in self.draftCommentActions.sendToAgent(bundle, target) }
        )
    }

    func inlineFeedbackAvailability(
        for item: DiffReviewInlineFeedback,
        file: DiffReviewFileSummary
    ) -> DiffReviewInlineFeedbackActionAvailability {
        inlineFeedbackActions.availability(item, file)
    }

    func draftCommentAvailability(for comment: ReviewDraftComment) -> ReviewDraftCommentActionAvailability {
        draftCommentActions.availability(comment)
    }

    func selectInlineFeedback(_ item: DiffReviewInlineFeedback) {
        onSelectInlineFeedback(item)
    }

    func selectDraftComment(_ comment: ReviewDraftComment) { onSelectDraftComment(comment) }
    func saveDraftComment(_ anchor: DiffReviewLineAnchor, body: String) { onSaveDraftComment(anchor, body) }
    func contextExpansionActivated() { onContextExpansionActivated() }
    func reply(to thread: DiffInlineCommentThread, body: String) { onReply(thread, body) }
    func stageReply(to thread: DiffInlineCommentThread, body: String) { onStageReply(thread, body) }
    func resolve(_ thread: DiffInlineCommentThread) { onResolve(thread) }
    func unresolve(_ thread: DiffInlineCommentThread) { onUnresolve(thread) }
    func edit(_ comment: DiffInlineComment, in thread: DiffInlineCommentThread, body: String) { onEdit(thread, comment, body) }
    func delete(_ comment: DiffInlineComment, in thread: DiffInlineCommentThread) { onDelete(thread, comment) }
    func openCurrentFile() { openFile?() }
    func unstageFile() { stagedMutationActions?.unstageFile?() }
    func hunkActions(for hunk: ParsedDiff.Hunk) -> DiffPaneHunkActions {
        let enabled = stagedMutationActions?.isHunkUnstageEnabled?(hunk) ?? false
        return .init(dropFromCommit: enabled ? { self.stagedMutationActions?.unstageHunk?(hunk) } : nil)
    }
}
