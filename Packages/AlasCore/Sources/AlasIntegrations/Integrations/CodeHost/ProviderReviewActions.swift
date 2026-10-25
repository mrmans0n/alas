import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures

public enum ProviderReviewDecision: String, Codable, Equatable, Sendable {
    case comment
    case approve
    case requestChanges

    public var requiresSummaryBody: Bool {
        switch self {
        case .comment, .approve:
            false
        case .requestChanges:
            true
        }
    }
}

public struct ProviderReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { localDraftID }
    public let localDraftID: String
    public let path: String
    public let originalPath: String?
    public let side: DiffReviewInlineFeedbackSide
    public let lineRange: ClosedRange<Int>
    public let selectedText: String?
    public let bodyMarkdown: String

    public init?(localDraft: ReviewDraftComment) {
        guard localDraft.state == .active,
              localDraft.providerPublish == nil,
              let lineRange = localDraft.normalizedLineRange else { return nil }
        self.localDraftID = localDraft.id
        self.path = localDraft.path
        self.originalPath = localDraft.originalPath
        self.side = localDraft.side
        self.lineRange = lineRange
        self.selectedText = localDraft.selectedText
        self.bodyMarkdown = localDraft.bodyMarkdown
    }
}

public struct ProviderReviewPublishRequest: Equatable, Sendable {
    public let remote: CodeHostRemote
    public let reviewRequest: ReviewRequest
    public let comments: [ProviderReviewDraftComment]
    public let decision: ProviderReviewDecision
    public let summaryBody: String
    public let cwd: URL

    public init(remote: CodeHostRemote, reviewRequest: ReviewRequest, comments: [ProviderReviewDraftComment], decision: ProviderReviewDecision, summaryBody: String, cwd: URL) {
        self.remote = remote
        self.reviewRequest = reviewRequest
        self.comments = comments
        self.decision = decision
        self.summaryBody = summaryBody
        self.cwd = cwd
    }
}

public struct ProviderReviewPublishedComment: Codable, Equatable, Sendable {
    public let localDraftID: String
    public let providerThreadID: String?
    public let providerCommentID: String?
    public let providerURL: URL?

    public init(localDraftID: String, providerThreadID: String?, providerCommentID: String?, providerURL: URL?) {
        self.localDraftID = localDraftID
        self.providerThreadID = providerThreadID
        self.providerCommentID = providerCommentID
        self.providerURL = providerURL
    }
}

public struct ProviderReviewFailedComment: Codable, Equatable, Sendable {
    public let localDraftID: String
    public let message: String

    public init(localDraftID: String, message: String) {
        self.localDraftID = localDraftID
        self.message = message
    }
}

public struct ProviderReviewPublishResult: Equatable, Sendable {
    public let published: [ProviderReviewPublishedComment]
    public let failed: [ProviderReviewFailedComment]
    public let refreshedRequest: ReviewRequest
    public let warnings: [String]

    public init(published: [ProviderReviewPublishedComment], failed: [ProviderReviewFailedComment], refreshedRequest: ReviewRequest, warnings: [String]) {
        self.published = published
        self.failed = failed
        self.refreshedRequest = refreshedRequest
        self.warnings = warnings
    }
}

public enum ProviderThreadMutationKind: String, Codable, Equatable, Sendable {
    case reply
    case resolve
    case unresolve
}

public struct ProviderThreadMutation: Equatable, Sendable {
    public let remote: CodeHostRemote
    public let reviewRequest: ReviewRequest
    public let thread: ReviewThreadSummary
    public let kind: ProviderThreadMutationKind
    public let bodyMarkdown: String?
    public let cwd: URL

    public init(remote: CodeHostRemote, reviewRequest: ReviewRequest, thread: ReviewThreadSummary, kind: ProviderThreadMutationKind, bodyMarkdown: String?, cwd: URL) {
        self.remote = remote
        self.reviewRequest = reviewRequest
        self.thread = thread
        self.kind = kind
        self.bodyMarkdown = bodyMarkdown
        self.cwd = cwd
    }
}

public struct ProviderThreadMutationResult: Equatable, Sendable {
    public let refreshedRequest: ReviewRequest
    public let providerURL: URL?
    public let warnings: [String]

    public init(refreshedRequest: ReviewRequest, providerURL: URL?, warnings: [String] = []) {
        self.refreshedRequest = refreshedRequest
        self.providerURL = providerURL
        self.warnings = warnings
    }
}

extension ProviderReviewPublishResult: Codable {}
extension ProviderThreadMutationResult: Codable {}

/// What became of one draft after a publish: the provider's identity for it,
/// or why the provider refused it.
public enum ProviderReviewDraftOutcome: Equatable, Sendable {
    case published(ReviewDraftProviderPublish)
    case failed(ReviewDraftProviderError)
}

public enum ProviderReviewPublishError: LocalizedError, Equatable, Sendable {
    case noPublishableSelectedDrafts
    case noPublishableDraftsForCommentReview

    public var errorDescription: String? {
        switch self {
        case .noPublishableSelectedDrafts:
            return "The selected draft is no longer publishable."
        case .noPublishableDraftsForCommentReview:
            return "There are no publishable draft comments for a comment review."
        }
    }
}

@MainActor
public enum ProviderReviewPublisher {
    /// Publishes the publishable `drafts` (only `localDraftIDs` when set), then
    /// hands `record` each draft's outcome, stamped with `now()` taken after the provider answers.
    public static func publish(
        _ drafts: [ReviewDraftComment],
        selecting localDraftIDs: Set<String>?,
        to reviewRequest: ReviewRequest,
        remote: CodeHostRemote,
        decision: ProviderReviewDecision,
        summaryBody: String,
        cwd: URL,
        provider: any CodeHostProvider,
        now: () -> Date,
        record: (_ draftID: String, _ outcome: ProviderReviewDraftOutcome) throws -> Void
    ) async throws -> ProviderReviewPublishResult {
        let sourceComments = drafts.filter { comment in
            localDraftIDs?.contains(comment.id) ?? true
        }
        let comments = ProviderReviewPublishPlanner.publishableDrafts(sourceComments)
            .compactMap(ProviderReviewDraftComment.init(localDraft:))
        if localDraftIDs != nil, comments.isEmpty {
            throw ProviderReviewPublishError.noPublishableSelectedDrafts
        }
        if localDraftIDs == nil, decision == .comment, comments.isEmpty {
            throw ProviderReviewPublishError.noPublishableDraftsForCommentReview
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
            try record(published.localDraftID, .published(ReviewDraftProviderPublish(
                provider: remote.kind,
                host: remote.host,
                repositorySlug: remote.repositorySlug,
                reviewNumber: reviewRequest.number,
                threadID: published.providerThreadID,
                commentID: published.providerCommentID,
                url: published.providerURL,
                publishedAt: timestamp
            )))
        }

        for failed in result.failed {
            try record(failed.localDraftID, .failed(ReviewDraftProviderError(
                provider: remote.kind,
                message: failed.message,
                occurredAt: timestamp
            )))
        }

        return result
    }
}

public enum ProviderReviewPublishPlanner {
    public static func publishableDrafts(_ drafts: [ReviewDraftComment]) -> [ReviewDraftComment] {
        drafts.filter { unpublishableReason(for: $0) == nil }
    }

    public static func unpublishableMessages(_ drafts: [ReviewDraftComment]) -> [String] {
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
