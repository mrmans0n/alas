import Foundation

@MainActor
struct ProviderReviewMutationController {
    let provider: any CodeHostProvider
    let draftController: ReviewDraftCommentController
    let now: () -> Date

    init(
        provider: any CodeHostProvider,
        draftController: ReviewDraftCommentController,
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.draftController = draftController
        self.now = now
    }

    func publishReview(
        remote: CodeHostRemote,
        reviewRequest: ReviewRequest,
        decision: ProviderReviewDecision,
        summaryBody: String,
        cwd: URL,
        localDraftIDs: Set<String>? = nil
    ) async throws -> ProviderReviewPublishResult {
        let sourceComments = draftController.comments.filter { comment in
            localDraftIDs?.contains(comment.id) ?? true
        }
        let comments = ProviderReviewPublishPlanner.publishableDrafts(sourceComments)
            .compactMap(ProviderReviewDraftComment.init(localDraft:))
        if localDraftIDs != nil, comments.isEmpty {
            throw ProviderReviewMutationControllerError.noPublishableSelectedDrafts
        }
        if localDraftIDs == nil, decision == .comment, comments.isEmpty {
            throw ProviderReviewMutationControllerError.noPublishableDraftsForCommentReview
        }
        let request = ProviderReviewPublishRequest(
            remote: remote,
            reviewRequest: reviewRequest,
            comments: comments,
            decision: decision,
            summaryBody: summaryBody,
            cwd: cwd
        )

        let result = try await provider.publishReview(request)
        let timestamp = now()

        for published in result.published {
            try draftController.markPublished(
                commentID: published.localDraftID,
                publish: ReviewDraftProviderPublish(
                    provider: remote.kind,
                    host: remote.host,
                    repositorySlug: remote.repositorySlug,
                    reviewNumber: reviewRequest.number,
                    threadID: published.providerThreadID,
                    commentID: published.providerCommentID,
                    url: published.providerURL,
                    publishedAt: timestamp
                )
            )
        }

        for failed in result.failed {
            try draftController.recordProviderError(
                commentID: failed.localDraftID,
                error: ReviewDraftProviderError(
                    provider: remote.kind,
                    message: failed.message,
                    occurredAt: timestamp
                )
            )
        }

        return result
    }

    func mutateThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        try await provider.mutateReviewThread(mutation)
    }
}

enum ProviderReviewPublishPlanner {
    static func publishableDrafts(_ drafts: [ReviewDraftComment]) -> [ReviewDraftComment] {
        drafts.filter { unpublishableReason(for: $0) == nil }
    }

    static func unpublishableMessages(_ drafts: [ReviewDraftComment]) -> [String] {
        drafts.compactMap { draft in
            guard let reason = unpublishableReason(for: draft) else { return nil }
            return "\(draft.path): \(reason)"
        }
    }

    private static func unpublishableReason(for draft: ReviewDraftComment) -> String? {
        if let publish = draft.providerPublish {
            return "already published to \(publish.provider.displayName)."
        }
        if draft.state != .active {
            return "draft is \(draft.state.providerPublishDescription)."
        }
        guard let lineRange = draft.normalizedLineRange else {
            return "missing line anchor."
        }
        if draft.side == .unknown || lineRange.lowerBound <= 0 {
            return "missing line anchor."
        }
        if draft.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "empty comment."
        }
        return nil
    }
}

private extension ReviewDraftCommentState {
    var providerPublishDescription: String {
        switch self {
        case .active:
            "active"
        case .resolved:
            "resolved"
        case .dismissed:
            "dismissed"
        }
    }
}

enum ProviderReviewMutationControllerError: LocalizedError, Equatable {
    case noPublishableSelectedDrafts
    case noPublishableDraftsForCommentReview

    var errorDescription: String? {
        switch self {
        case .noPublishableSelectedDrafts:
            return "The selected draft is no longer publishable."
        case .noPublishableDraftsForCommentReview:
            return "There are no publishable draft comments for a comment review."
        }
    }
}
