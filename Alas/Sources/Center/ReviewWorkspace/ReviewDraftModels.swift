import Foundation

enum ReviewDraftSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case commit
    case draftCommit = "draft-commit"
    case branch
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}

enum ReviewDraftLocalChangesScope: String, Codable, Equatable, Hashable, Sendable {
    case all
    case unstaged
    case staged
}

struct ReviewDraftSessionID: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    let rawValue: String
    let sourceKind: ReviewDraftSourceKind

    init(rawValue: String, sourceKind: ReviewDraftSourceKind) {
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first,
              let sourceKind = ReviewDraftSourceKind(rawValue: first)
        else { return nil }
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    static func localChanges(worktreeID: String, worktreePath: URL, scope: ReviewDraftLocalChangesScope) -> Self {
        make(.localChanges, [worktreeID, worktreePath.standardizedFileURL.path, scope.rawValue])
    }

    static func commit(worktreeID: String, repositoryPath: URL, sha: String) -> Self {
        make(.commit, [worktreeID, repositoryPath.standardizedFileURL.path, sha])
    }

    static func draftCommit(worktreeID: String, repositoryPath: URL) -> Self {
        make(.draftCommit, [worktreeID, repositoryPath.standardizedFileURL.path])
    }

    static func branch(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.branch, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    static func reviewRequest(
        worktreeID: String,
        provider: CodeHostKind,
        host: String,
        repositorySlug: String,
        number: Int
    ) -> Self {
        make(.reviewRequest, [worktreeID, provider.rawValue, host.lowercased(), repositorySlug, "\(number)"])
    }

    static func draftReviewRequest(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.draftReviewRequest, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    private static let separator: Character = "\u{1f}"

    private static func make(_ kind: ReviewDraftSourceKind, _ fields: [String]) -> Self {
        let escapedFields = ([kind.rawValue] + fields).map(escape)
        return ReviewDraftSessionID(rawValue: escapedFields.joined(separator: String(separator)), sourceKind: kind)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: String(separator), with: "\\u001f")
    }
}

enum ReviewDraftCommentState: String, Codable, Equatable, Hashable, Sendable {
    case active
    case resolved
    case dismissed
}

struct ReviewDraftProviderPublish: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
    let reviewNumber: Int
    let threadID: String?
    let commentID: String?
    let url: URL?
    let publishedAt: Date
}

struct ReviewDraftProviderError: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let message: String
    let occurredAt: Date
}

struct ReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sessionID: ReviewDraftSessionID
    var fileID: DiffReviewFileID
    var path: String
    var originalPath: String?
    var side: DiffReviewInlineFeedbackSide
    var startLine: Int
    var endLine: Int?
    var selectedText: String?
    var bodyMarkdown: String
    var state: ReviewDraftCommentState
    var createdAt: Date
    var updatedAt: Date
    var providerPublish: ReviewDraftProviderPublish? = nil
    var providerError: ReviewDraftProviderError? = nil

    var normalizedLineRange: ClosedRange<Int> {
        let end = endLine ?? startLine
        return min(startLine, end)...max(startLine, end)
    }

    var isActive: Bool { state == .active }
}
