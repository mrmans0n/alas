struct ReviewDraftCommentActionAvailability: Equatable, Sendable {
    var canEdit: Bool
    var canDelete: Bool
    var canResolve: Bool
    var canDismiss: Bool
    var canCopyPrompt: Bool
    var canShowSendToAgent: Bool
    var canSendToAgent: Bool

    static let none = ReviewDraftCommentActionAvailability(
        canEdit: false,
        canDelete: false,
        canResolve: false,
        canDismiss: false,
        canCopyPrompt: false,
        canShowSendToAgent: false,
        canSendToAgent: false
    )
}

struct ReviewDraftCommentActions {
    var availability: (ReviewDraftComment) -> ReviewDraftCommentActionAvailability
    var edit: (ReviewDraftComment) -> Void
    var delete: (ReviewDraftComment) -> Void
    var resolve: (ReviewDraftComment) -> Void
    var dismiss: (ReviewDraftComment) -> Void
    var copyPrompt: (ReviewFeedbackBundle) -> Void
    var sendToAgent: (ReviewFeedbackBundle) -> Void

    init(
        availability: @escaping (ReviewDraftComment) -> ReviewDraftCommentActionAvailability = { _ in .none },
        edit: @escaping (ReviewDraftComment) -> Void = { _ in },
        delete: @escaping (ReviewDraftComment) -> Void = { _ in },
        resolve: @escaping (ReviewDraftComment) -> Void = { _ in },
        dismiss: @escaping (ReviewDraftComment) -> Void = { _ in },
        copyPrompt: @escaping (ReviewFeedbackBundle) -> Void = { _ in },
        sendToAgent: @escaping (ReviewFeedbackBundle) -> Void = { _ in }
    ) {
        self.availability = availability
        self.edit = edit
        self.delete = delete
        self.resolve = resolve
        self.dismiss = dismiss
        self.copyPrompt = copyPrompt
        self.sendToAgent = sendToAgent
    }
}
