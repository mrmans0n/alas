import Foundation

enum ReviewDraftSourceKind: String, Codable, Equatable, Hashable, Sendable {
    case localChanges = "local-changes"
    case commit
    case trackedCommit = "tracked-commit"
    case commitRange = "commit-range"
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

    static func trackedCommit(worktreeID: String, repositoryPath: URL, targetKey: String) -> Self {
        make(.trackedCommit, [worktreeID, repositoryPath.standardizedFileURL.path, targetKey])
    }

    static func commitRange(worktreeID: String, repositoryPath: URL, base: String, head: String) -> Self {
        make(.commitRange, [worktreeID, repositoryPath.standardizedFileURL.path, base, head])
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

    /// Every factory puts the worktree ID in field 1, so a session ID can be
    /// scoped to a worktree without decoding the rest of its fields.
    func isFor(worktreeID: String) -> Bool {
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        return parts[1] == Self.escape(worktreeID)
    }

    /// The code host for a `.reviewRequest` session id, decoded from its raw
    /// fields (`reviewRequest`'s second field is always `provider.rawValue`).
    /// nil for any other `sourceKind`.
    var reviewRequestProvider: CodeHostKind? {
        guard sourceKind == .reviewRequest else { return nil }
        let parts = rawValue.split(separator: Self.separator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        return CodeHostKind(rawValue: parts[2])
    }

    /// The scope for a `.localChanges` session id, decoded from its raw
    /// fields (`localChanges`'s third field is always `scope.rawValue`).
    /// nil for any other `sourceKind`.
    var localChangesScope: ReviewDraftLocalChangesScope? {
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

enum ReviewDraftCommentState: String, Codable, Equatable, Hashable, Sendable {
    case active
    case resolved
    case dismissed
}

/// Who wrote a review comment or reply. Legacy comments (no author on
/// disk) decode as nil and are treated as `.user`.
enum ReviewDraftCommentAuthor: Codable, Equatable, Hashable, Sendable {
    case user
    case agent(name: String)

    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .user:
            return "You"
        case .agent(let name):
            return name.isEmpty ? "Agent" : name
        }
    }
}

struct ReviewCommentReply: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let author: ReviewDraftCommentAuthor
    let bodyMarkdown: String
    let createdAt: Date
}

struct ReviewDraftProviderPublish: Codable, Equatable, Hashable, Sendable {
    let provider: CodeHostKind
    let host: String
    let repositorySlug: String
    let reviewNumber: Int
    let threadID: String?
    let commentID: String?
    let url: URL?
    let publishedAt: Date
}

struct ReviewDraftProviderError: Codable, Equatable, Hashable, Sendable {
    let provider: CodeHostKind
    let message: String
    let occurredAt: Date
}

enum ReviewDraftCommentAnchor: Codable, Equatable, Hashable, Sendable {
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

    var side: DiffReviewInlineFeedbackSide {
        switch self {
        case .file: .unknown
        case .line(let side, _, _, _), .image(let side, _, _): side
        }
    }

    var lineRange: ClosedRange<Int>? {
        guard case .line(_, let startLine, let endLine, _) = self else { return nil }
        let end = endLine ?? startLine
        return min(startLine, end)...max(startLine, end)
    }
}

struct ReviewDraftComment: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var sessionID: ReviewDraftSessionID
    var fileID: DiffReviewFileID
    var path: String
    var originalPath: String?
    var anchor: ReviewDraftCommentAnchor
    var bodyMarkdown: String
    var state: ReviewDraftCommentState
    var createdAt: Date
    var updatedAt: Date
    var providerPublish: ReviewDraftProviderPublish? = nil
    var providerError: ReviewDraftProviderError? = nil
    var author: ReviewDraftCommentAuthor? = nil
    var replies: [ReviewCommentReply]? = nil
    var resolvedBy: ReviewDraftCommentAuthor? = nil

    var side: DiffReviewInlineFeedbackSide { anchor.side }
    var normalizedLineRange: ClosedRange<Int>? { anchor.lineRange }
    var startLine: Int {
        guard case .line(_, let startLine, _, _) = anchor else { return 0 }
        return startLine
    }
    var endLine: Int? {
        guard case .line(_, _, let endLine, _) = anchor else { return nil }
        return endLine
    }
    var selectedText: String? {
        get {
            guard case .line(_, _, _, let selectedText) = anchor else { return nil }
            return selectedText
        }
        set {
            guard case .line(let side, let startLine, let endLine, _) = anchor else { return }
            anchor = .line(side: side, startLine: startLine, endLine: endLine, selectedText: newValue)
        }
    }

    var isActive: Bool { state == .active }
    var effectiveAuthor: ReviewDraftCommentAuthor { author ?? .user }
    var allReplies: [ReviewCommentReply] { replies ?? [] }

    init(
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

    init(
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
