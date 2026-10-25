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
        try await ProviderReviewPublisher.publish(
            draftController.comments,
            selecting: localDraftIDs,
            to: reviewRequest,
            remote: remote,
            decision: decision,
            summaryBody: summaryBody,
            cwd: cwd,
            provider: provider,
            now: now
        ) { draftID, outcome in
            switch outcome {
            case .published(let publish):
                try draftController.markPublished(commentID: draftID, publish: publish)
            case .failed(let error):
                try draftController.recordProviderError(commentID: draftID, error: error)
            }
        }
    }

    func mutateThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
        try await provider.mutateReviewThread(mutation)
    }
}
