struct ReviewDraftCommentActionAvailability: Equatable, Sendable {
    var canEdit: Bool
    var canDelete: Bool
    var canResolve: Bool
    var canDismiss: Bool
    var canCopyPrompt: Bool
    var canShowSendToAgent: Bool
    var canSendToAgent: Bool
    var canPublishProvider: Bool

    init(
        canEdit: Bool,
        canDelete: Bool,
        canResolve: Bool,
        canDismiss: Bool,
        canCopyPrompt: Bool,
        canShowSendToAgent: Bool,
        canSendToAgent: Bool,
        canPublishProvider: Bool = false
    ) {
        self.canEdit = canEdit
        self.canDelete = canDelete
        self.canResolve = canResolve
        self.canDismiss = canDismiss
        self.canCopyPrompt = canCopyPrompt
        self.canShowSendToAgent = canShowSendToAgent
        self.canSendToAgent = canSendToAgent
        self.canPublishProvider = canPublishProvider
    }

    static let none = ReviewDraftCommentActionAvailability(
        canEdit: false,
        canDelete: false,
        canResolve: false,
        canDismiss: false,
        canCopyPrompt: false,
        canShowSendToAgent: false,
        canSendToAgent: false,
        canPublishProvider: false
    )
}

struct ReviewDraftCommentActions {
    var availability: (ReviewDraftComment) -> ReviewDraftCommentActionAvailability
    var canPublishReview: () -> Bool
    var edit: (ReviewDraftComment, String) -> Void
    var delete: (ReviewDraftComment) -> Void
    var resolve: (ReviewDraftComment) -> Void
    var dismiss: (ReviewDraftComment) -> Void
    var copyPrompt: (ReviewFeedbackBundle) -> Void
    var publishProvider: (ReviewDraftComment) -> Void
    var publishReview: () -> Void
    var agent: (ReviewFeedbackAgentTarget) -> AgentDefinition?
    var agentTargets: () -> [ReviewFeedbackAgentTarget]
    var sendToAgent: (ReviewFeedbackBundle, ReviewFeedbackAgentTarget) -> Void

    init(
        availability: @escaping (ReviewDraftComment) -> ReviewDraftCommentActionAvailability = { _ in .none },
        canPublishReview: @escaping () -> Bool = { false },
        edit: @escaping (ReviewDraftComment, String) -> Void = { _, _ in },
        delete: @escaping (ReviewDraftComment) -> Void = { _ in },
        resolve: @escaping (ReviewDraftComment) -> Void = { _ in },
        dismiss: @escaping (ReviewDraftComment) -> Void = { _ in },
        copyPrompt: @escaping (ReviewFeedbackBundle) -> Void = { _ in },
        publishProvider: @escaping (ReviewDraftComment) -> Void = { _ in },
        publishReview: @escaping () -> Void = {},
        agent: @escaping (ReviewFeedbackAgentTarget) -> AgentDefinition? = { _ in nil },
        agentTargets: @escaping () -> [ReviewFeedbackAgentTarget] = { [] },
        sendToAgent: @escaping (ReviewFeedbackBundle, ReviewFeedbackAgentTarget) -> Void = { _, _ in }
    ) {
        self.availability = availability
        self.canPublishReview = canPublishReview
        self.edit = edit
        self.delete = delete
        self.resolve = resolve
        self.dismiss = dismiss
        self.copyPrompt = copyPrompt
        self.publishProvider = publishProvider
        self.publishReview = publishReview
        self.agent = agent
        self.agentTargets = agentTargets
        self.sendToAgent = sendToAgent
    }
}
