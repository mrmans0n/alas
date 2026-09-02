import Foundation

enum ProviderReviewDecision: String, Codable, Equatable, Sendable {
    case comment
    case approve
    case requestChanges

    var requiresSummaryBody: Bool {
        switch self {
        case .comment, .approve:
            false
        case .requestChanges:
            true
        }
    }
}

struct ProviderReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    var id: String { localDraftID }
    let localDraftID: String
    let path: String
    let originalPath: String?
    let side: DiffReviewInlineFeedbackSide
    let lineRange: ClosedRange<Int>
    let selectedText: String?
    let bodyMarkdown: String

    init?(localDraft: ReviewDraftComment) {
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

struct ProviderReviewPublishRequest: Equatable, Sendable {
    let remote: CodeHostRemote
    let reviewRequest: ReviewRequest
    let comments: [ProviderReviewDraftComment]
    let decision: ProviderReviewDecision
    let summaryBody: String
    let cwd: URL
}

struct ProviderReviewPublishedComment: Codable, Equatable, Sendable {
    let localDraftID: String
    let providerThreadID: String?
    let providerCommentID: String?
    let providerURL: URL?
}

struct ProviderReviewFailedComment: Codable, Equatable, Sendable {
    let localDraftID: String
    let message: String
}

struct ProviderReviewPublishResult: Equatable, Sendable {
    let published: [ProviderReviewPublishedComment]
    let failed: [ProviderReviewFailedComment]
    let refreshedRequest: ReviewRequest
    let warnings: [String]
}

enum ProviderThreadMutationKind: String, Codable, Equatable, Sendable {
    case reply
    case resolve
    case unresolve
}

struct ProviderThreadMutation: Equatable, Sendable {
    let remote: CodeHostRemote
    let reviewRequest: ReviewRequest
    let thread: ReviewThreadSummary
    let kind: ProviderThreadMutationKind
    let bodyMarkdown: String?
    let cwd: URL
}

struct ProviderThreadMutationResult: Equatable, Sendable {
    let refreshedRequest: ReviewRequest
    let providerURL: URL?
    let warnings: [String]

    init(refreshedRequest: ReviewRequest, providerURL: URL?, warnings: [String] = []) {
        self.refreshedRequest = refreshedRequest
        self.providerURL = providerURL
        self.warnings = warnings
    }
}
