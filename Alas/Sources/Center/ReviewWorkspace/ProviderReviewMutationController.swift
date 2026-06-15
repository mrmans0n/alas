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
        let sourceComments = draftController.activeUnpublishedComments.filter { comment in
            localDraftIDs?.contains(comment.id) ?? true
        }
        let comments = sourceComments.compactMap(ProviderReviewDraftComment.init(localDraft:))
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
