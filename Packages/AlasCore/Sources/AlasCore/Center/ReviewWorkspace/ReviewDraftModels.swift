import Foundation

public enum ReviewDraftSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case commit
    case trackedCommit = "tracked-commit"
    case commitRange = "commit-range"
    case draftCommit = "draft-commit"
    case branch
    case branchWithLocalChanges = "branch-with-local-changes"
    case sinceSnapshot = "since-snapshot"
    case reviewRequest = "review-request"
    case draftReviewRequest = "draft-review-request"
}

public enum ReviewDraftLocalChangesScope: String, Codable, Equatable, Hashable, Sendable {
    case all
    case unstaged
    case staged
}

public struct ReviewDraftSessionID: Codable, Equatable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public let sourceKind: ReviewDraftSourceKind

    public init(rawValue: String, sourceKind: ReviewDraftSourceKind) {
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first,
              let sourceKind = ReviewDraftSourceKind(rawValue: first)
        else { return nil }
        self.rawValue = rawValue
        self.sourceKind = sourceKind
    }

    public static func localChanges(worktreeID: String, worktreePath: URL, scope: ReviewDraftLocalChangesScope) -> Self {
        make(.localChanges, [worktreeID, worktreePath.standardizedFileURL.path, scope.rawValue])
    }

    public static func commit(worktreeID: String, repositoryPath: URL, sha: String) -> Self {
        make(.commit, [worktreeID, repositoryPath.standardizedFileURL.path, sha])
    }

    public static func trackedCommit(worktreeID: String, repositoryPath: URL, targetKey: String) -> Self {
        make(.trackedCommit, [worktreeID, repositoryPath.standardizedFileURL.path, targetKey])
    }

    public static func commitRange(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.commitRange, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    public static func draftCommit(worktreeID: String, repositoryPath: URL) -> Self {
        make(.draftCommit, [worktreeID, repositoryPath.standardizedFileURL.path])
    }

    public static func branch(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.branch, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    public static func branchWithLocalChanges(worktreeID: String, repositoryPath: URL, base: String) -> Self {
        make(.branchWithLocalChanges, [worktreeID, repositoryPath.standardizedFileURL.path, base])
    }

    public static func sinceSnapshot(worktreeID: String, repositoryPath: URL, tree: String) -> Self {
        make(.sinceSnapshot, [worktreeID, repositoryPath.standardizedFileURL.path, tree])
    }

    public static func reviewRequest(
        worktreeID: String,
        provider: CodeHostKind,
        host: String,
        repositorySlug: String,
        number: Int
    ) -> Self {
        make(.reviewRequest, [worktreeID, provider.rawValue, host.lowercased(), repositorySlug, "\(number)"])
    }

    public static func draftReviewRequest(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.draftReviewRequest, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
    }

    public func matchesDraftReviewRequest(worktreeID: String, base: String, head: String) -> Bool {
        guard sourceKind == .draftReviewRequest else { return false }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        return parts.count == 5
            && parts[1] == Self.escape(worktreeID)
            && parts[3] == Self.escape(base)
            && parts[4] == Self.escape(head)
    }

    /// Every factory puts the worktree ID in field 1, so a session ID can be
    /// scoped to a worktree without decoding the rest of its fields.
    public func isFor(worktreeID: String) -> Bool {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        return parts[1] == Self.escape(worktreeID)
    }

    /// The code host for a `.reviewRequest` session id, decoded from its raw
    /// fields (`reviewRequest`'s second field is always `provider.rawValue`).
    /// nil for any other `sourceKind`.
    public var reviewRequestProvider: CodeHostKind? {
        guard sourceKind == .reviewRequest else { return nil }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return CodeHostKind(rawValue: parts[2])
    }

    /// The scope for a `.localChanges` session id, decoded from its raw
    /// fields (`localChanges`'s third field is always `scope.rawValue`).
    /// nil for any other `sourceKind`.
    public var localChangesScope: ReviewDraftLocalChangesScope? {
        guard sourceKind == .localChanges else { return nil }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4 else { return nil }
        return ReviewDraftLocalChangesScope(rawValue: parts[3])
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

public enum ReviewDraftCommentState: String, Codable, Equatable, Hashable, Sendable {
    case active
    case resolved
    case dismissed
}

/// Who wrote a review comment or reply. Legacy comments (no author on
/// disk) decode as nil and are treated as `.user`.
public enum ReviewDraftCommentAuthor: Codable, Equatable, Hashable, Sendable {
    case user
    case agent(name: String)

    public var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .user:
            return "You"
        case .agent(let name):
            return name.isEmpty ? "Agent" : name
        }
    }
}

public struct ReviewCommentReply: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let author: ReviewDraftCommentAuthor
    public let bodyMarkdown: String
    public let createdAt: Date

    public init(id: String, author: ReviewDraftCommentAuthor, bodyMarkdown: String, createdAt: Date) {
        self.id = id
        self.author = author
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
    }
}

public struct ReviewDraftProviderPublish: Codable, Equatable, Hashable, Sendable {
    public let provider: CodeHostKind
    public let host: String
    public let repositorySlug: String
    public let reviewNumber: Int
    public let threadID: String?
    public let commentID: String?
    public let url: URL?
    public let publishedAt: Date

    public init(provider: CodeHostKind, host: String, repositorySlug: String, reviewNumber: Int, threadID: String?, commentID: String?, url: URL?, publishedAt: Date) {
        self.provider = provider
        self.host = host
        self.repositorySlug = repositorySlug
        self.reviewNumber = reviewNumber
        self.threadID = threadID
        self.commentID = commentID
        self.url = url
        self.publishedAt = publishedAt
    }
}

public struct ReviewDraftProviderError: Codable, Equatable, Hashable, Sendable {
    public let provider: CodeHostKind
    public let message: String
    public let occurredAt: Date

    public init(provider: CodeHostKind, message: String, occurredAt: Date) {
        self.provider = provider
        self.message = message
        self.occurredAt = occurredAt
    }
}

public enum ReviewDraftCommentAnchor: Codable, Equatable, Hashable, Sendable {
    case file
    case line(
        side: DiffReviewInlineFeedbackSide,
        startLine: Int,
        endLine: Int?,
        selectedText: String?
    )
    case image(
        side: DiffReviewInlineFeedbackSide,
        normalizedX: Double,
        normalizedY: Double
    )

    public var side: DiffReviewInlineFeedbackSide {
        switch self {
        case .file: .unknown
        case .line(let side, _, _, _), .image(let side, _, _): side
        }
    }

    public var lineRange: ClosedRange<Int>? {
        guard case .line(_, let startLine, let endLine, _) = self else { return nil }
        let end = endLine ?? startLine
        return min(startLine, end)...max(startLine, end)
    }
}

public struct ReviewDraftComment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sessionID: ReviewDraftSessionID
    public var fileID: DiffReviewFileID
    public var path: String
    public var originalPath: String?
    public var anchor: ReviewDraftCommentAnchor
    public var bodyMarkdown: String
    public var state: ReviewDraftCommentState
    public var createdAt: Date
    public var updatedAt: Date
    public var providerPublish: ReviewDraftProviderPublish? = nil
    public var providerError: ReviewDraftProviderError? = nil
    public var author: ReviewDraftCommentAuthor? = nil
    public var replies: [ReviewCommentReply]? = nil
    public var resolvedBy: ReviewDraftCommentAuthor? = nil

    public var side: DiffReviewInlineFeedbackSide { anchor.side }
    public var normalizedLineRange: ClosedRange<Int>? { anchor.lineRange }
    public var startLine: Int {
        guard case .line(_, let startLine, _, _) = anchor else { return 0 }
        return startLine
    }
    public var endLine: Int? {
        guard case .line(_, _, let endLine, _) = anchor else { return nil }
        return endLine
    }
    public var selectedText: String? {
        get {
            guard case .line(_, _, _, let selectedText) = anchor else { return nil }
            return selectedText
        }
        set {
            guard case .line(let side, let startLine, let endLine, _) = anchor else { return }
            anchor = .line(side: side, startLine: startLine, endLine: endLine, selectedText: newValue)
        }
    }

    public var isActive: Bool { state == .active }
    public var effectiveAuthor: ReviewDraftCommentAuthor { author ?? .user }
    public var allReplies: [ReviewCommentReply] { replies ?? [] }

    public init(
        id: String,
        sessionID: ReviewDraftSessionID,
        fileID: DiffReviewFileID,
        path: String,
        originalPath: String? = nil,
        anchor: ReviewDraftCommentAnchor,
        bodyMarkdown: String,
        state: ReviewDraftCommentState,
        createdAt: Date,
        updatedAt: Date,
        providerPublish: ReviewDraftProviderPublish? = nil,
        providerError: ReviewDraftProviderError? = nil,
        author: ReviewDraftCommentAuthor? = nil,
        replies: [ReviewCommentReply]? = nil,
        resolvedBy: ReviewDraftCommentAuthor? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.fileID = fileID
        self.path = path
        self.originalPath = originalPath
        self.anchor = anchor
        self.bodyMarkdown = bodyMarkdown
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerPublish = providerPublish
        self.providerError = providerError
        self.author = author
        self.replies = replies
        self.resolvedBy = resolvedBy
    }

    public init(
        id: String,
        sessionID: ReviewDraftSessionID,
        fileID: DiffReviewFileID,
        path: String,
        originalPath: String? = nil,
        side: DiffReviewInlineFeedbackSide,
        startLine: Int,
        endLine: Int? = nil,
        selectedText: String? = nil,
        bodyMarkdown: String,
        state: ReviewDraftCommentState,
        createdAt: Date,
        updatedAt: Date,
        providerPublish: ReviewDraftProviderPublish? = nil,
        providerError: ReviewDraftProviderError? = nil,
        author: ReviewDraftCommentAuthor? = nil,
        replies: [ReviewCommentReply]? = nil,
        resolvedBy: ReviewDraftCommentAuthor? = nil
    ) {
        self.init(
            id: id,
            sessionID: sessionID,
            fileID: fileID,
            path: path,
            originalPath: originalPath,
            anchor: .line(
                side: side,
                startLine: startLine,
                endLine: endLine,
                selectedText: selectedText
            ),
            bodyMarkdown: bodyMarkdown,
            state: state,
            createdAt: createdAt,
            updatedAt: updatedAt,
            providerPublish: providerPublish,
            providerError: providerError,
            author: author,
            replies: replies,
            resolvedBy: resolvedBy
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, fileID, path, originalPath, anchor
        case side, startLine, endLine, selectedText
        case bodyMarkdown, state, createdAt, updatedAt
        case providerPublish, providerError, author, replies, resolvedBy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(ReviewDraftSessionID.self, forKey: .sessionID)
        fileID = try container.decode(DiffReviewFileID.self, forKey: .fileID)
        path = try container.decode(String.self, forKey: .path)
        originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
        if let decodedAnchor = try container.decodeIfPresent(ReviewDraftCommentAnchor.self, forKey: .anchor) {
            anchor = decodedAnchor
        } else {
            anchor = .line(
                side: try container.decode(DiffReviewInlineFeedbackSide.self, forKey: .side),
                startLine: try container.decode(Int.self, forKey: .startLine),
                endLine: try container.decodeIfPresent(Int.self, forKey: .endLine),
                selectedText: try container.decodeIfPresent(String.self, forKey: .selectedText)
            )
        }
        bodyMarkdown = try container.decode(String.self, forKey: .bodyMarkdown)
        state = try container.decode(ReviewDraftCommentState.self, forKey: .state)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        providerPublish = try container.decodeIfPresent(ReviewDraftProviderPublish.self, forKey: .providerPublish)
        providerError = try container.decodeIfPresent(ReviewDraftProviderError.self, forKey: .providerError)
        author = try container.decodeIfPresent(ReviewDraftCommentAuthor.self, forKey: .author)
        replies = try container.decodeIfPresent([ReviewCommentReply].self, forKey: .replies)
        resolvedBy = try container.decodeIfPresent(ReviewDraftCommentAuthor.self, forKey: .resolvedBy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(fileID, forKey: .fileID)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(originalPath, forKey: .originalPath)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(bodyMarkdown, forKey: .bodyMarkdown)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(providerPublish, forKey: .providerPublish)
        try container.encodeIfPresent(providerError, forKey: .providerError)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(replies, forKey: .replies)
        try container.encodeIfPresent(resolvedBy, forKey: .resolvedBy)
    }
}
