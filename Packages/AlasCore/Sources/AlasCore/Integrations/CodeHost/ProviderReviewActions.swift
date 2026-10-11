import Foundation

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
