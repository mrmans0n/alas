struct ReviewDraftCommentActionAvailability: Equatable, Sendable {
    var canEdit: Bool
    var canDelete: Bool
    var canResolve: Bool
    var canCopyPrompt: Bool
    var canSendToAgent: Bool

    static let none = ReviewDraftCommentActionAvailability(
        canEdit: false,
        canDelete: false,
        canResolve: false,
        canCopyPrompt: false,
        canSendToAgent: false
    )
}

struct ReviewDraftCommentActions: Sendable {
    var availability: @Sendable (ReviewDraftComment) -> ReviewDraftCommentActionAvailability
    var edit: @Sendable (ReviewDraftComment) -> Void
    var delete: @Sendable (ReviewDraftComment) -> Void
    var resolve: @Sendable (ReviewDraftComment) -> Void
    var copyPrompt: @Sendable (ReviewFeedbackBundle) -> Void
    var sendToAgent: @Sendable (ReviewFeedbackBundle) -> Void

    init(
        availability: @escaping @Sendable (ReviewDraftComment) -> ReviewDraftCommentActionAvailability = { _ in .none },
        edit: @escaping @Sendable (ReviewDraftComment) -> Void = { _ in },
        delete: @escaping @Sendable (ReviewDraftComment) -> Void = { _ in },
        resolve: @escaping @Sendable (ReviewDraftComment) -> Void = { _ in },
        copyPrompt: @escaping @Sendable (ReviewFeedbackBundle) -> Void = { _ in },
        sendToAgent: @escaping @Sendable (ReviewFeedbackBundle) -> Void = { _ in }
    ) {
        self.availability = availability
        self.edit = edit
        self.delete = delete
        self.resolve = resolve
        self.copyPrompt = copyPrompt
        self.sendToAgent = sendToAgent
    }
}
