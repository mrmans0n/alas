import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

public struct CodeHostRemote: Codable, Equatable, Sendable {
    public let kind: CodeHostKind
    public let host: String
    public let owner: String
    public let repository: String
    public let remoteName: String
    public let webURL: URL

    public var repositorySlug: String { "\(owner)/\(repository)" }

    public func commitURL(sha: String) -> URL {
        switch kind {
        case .github:
            return webURL.appendingPathComponent("commit").appendingPathComponent(sha)
        case .gitlab:
            return webURL.appendingPathComponent("-").appendingPathComponent("commit").appendingPathComponent(sha)
        }
    }

    public func reviewRequestURL(number: Int) -> URL {
        switch kind {
        case .github:
            return webURL.appendingPathComponent("pull").appendingPathComponent("\(number)")
        case .gitlab:
            return webURL.appendingPathComponent("-")
                .appendingPathComponent("merge_requests").appendingPathComponent("\(number)")
        }
    }

    public static func recoveredReviewRequestRemote(
        provider: CodeHostKind,
        repositorySlug: String,
        number: Int,
        url: URL,
        knownRemotes: [CodeHostRemote]
    ) -> CodeHostRemote? {
        if let known = knownRemotes.first(where: {
            $0.kind == provider && $0.repositorySlug == repositorySlug
                && $0.reviewRequestURL(number: number) == url
        }) { return known }

        let slug = repositorySlug.split(separator: "/").map(String.init)
        guard number > 0, slug.count >= 2,
              provider == .gitlab || slug.count == 2,
              let host = url.host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, scheme == "https" || scheme == "http"
        else { return nil }
        components.path = "/" + repositorySlug
        components.query = nil
        components.fragment = nil
        guard let webURL = components.url else { return nil }
        let remote = CodeHostRemote(
            kind: provider, host: host,
            owner: slug.dropLast().joined(separator: "/"), repository: slug.last!,
            remoteName: "origin", webURL: webURL
        )
        return remote.reviewRequestURL(number: number) == url ? remote : nil
    }

    public init(kind: CodeHostKind, host: String, owner: String, repository: String, remoteName: String, webURL: URL) {
        self.kind = kind
        self.host = host
        self.owner = owner
        self.repository = repository
        self.remoteName = remoteName
        self.webURL = webURL
    }
}

public struct CodeHostProviderCapabilities: Equatable, Sendable {
    public let canCreateReviewRequest: Bool
    public let canRerunFailedChecks: Bool
    public let canOpenReviewRequest: Bool
    public let canReply: Bool
    public let canResolve: Bool
    public let canComment: Bool
    public let canSubmitReview: Bool
    public let canFetchAnnotations: Bool
    public let canEditComment: Bool
    public let canDeleteComment: Bool
    public let canMerge: Bool

    public static let readOnly = CodeHostProviderCapabilities(
        canCreateReviewRequest: false,
        canRerunFailedChecks: false,
        canOpenReviewRequest: true,
        canReply: false,
        canResolve: false,
        canComment: false,
        canSubmitReview: false,
        canFetchAnnotations: false,
        canEditComment: false,
        canDeleteComment: false,
        canMerge: false
    )

    public static let githubCLI = CodeHostProviderCapabilities(
        canCreateReviewRequest: true,
        canRerunFailedChecks: true,
        canOpenReviewRequest: true,
        canReply: true,
        canResolve: true,
        canComment: true,
        canSubmitReview: true,
        canFetchAnnotations: true,
        canEditComment: true,
        canDeleteComment: true,
        canMerge: true
    )

    public static let gitlabCLI = CodeHostProviderCapabilities(
        canCreateReviewRequest: true,
        canRerunFailedChecks: true,
        canOpenReviewRequest: true,
        canReply: true,
        canResolve: true,
        canComment: true,
        canSubmitReview: true,
        canFetchAnnotations: false,
        canEditComment: true,
        canDeleteComment: true,
        canMerge: true
    )

    public init(canCreateReviewRequest: Bool, canRerunFailedChecks: Bool, canOpenReviewRequest: Bool, canReply: Bool, canResolve: Bool, canComment: Bool, canSubmitReview: Bool, canFetchAnnotations: Bool, canEditComment: Bool, canDeleteComment: Bool, canMerge: Bool) {
        self.canCreateReviewRequest = canCreateReviewRequest
        self.canRerunFailedChecks = canRerunFailedChecks
        self.canOpenReviewRequest = canOpenReviewRequest
        self.canReply = canReply
        self.canResolve = canResolve
        self.canComment = canComment
        self.canSubmitReview = canSubmitReview
        self.canFetchAnnotations = canFetchAnnotations
        self.canEditComment = canEditComment
        self.canDeleteComment = canDeleteComment
        self.canMerge = canMerge
    }
}

public enum ReviewRequestState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case merged
}

public enum ReviewDecision: String, Codable, Equatable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
    case unknown
}

public enum ReviewMergeState: String, Codable, Equatable, Sendable {
    case clean
    case blocked
    case dirty
    case unstable
    case unknown
}

public enum ReviewMergeMethod: String, Codable, Equatable, Sendable {
    case squash
    case merge
    case rebase
}

public enum ReviewCheckBucket: String, Codable, Equatable, Sendable {
    case pass
    case fail
    case pending
    case skipping
    case cancel
    case unknown

    public var severity: Int {
        switch self {
        case .fail: 50
        case .pending: 40
        case .cancel: 30
        case .unknown: 20
        case .pass: 10
        case .skipping: 0
        }
    }
}

public struct ReviewCheck: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let workflow: String?
    public let bucket: ReviewCheckBucket
    public let detailURL: URL?
    public let completedAt: Date?

    public init(id: String, name: String, workflow: String?, bucket: ReviewCheckBucket, detailURL: URL?, completedAt: Date?) {
        self.id = id
        self.name = name
        self.workflow = workflow
        self.bucket = bucket
        self.detailURL = detailURL
        self.completedAt = completedAt
    }
}

public struct CheckAnnotation: Identifiable, Equatable, Sendable {
    public var id: String { "\(checkRunID)-\(path)-\(startLine)-\(endLine)-\(level.rawValue)-\(message.hashValue)" }
    public let checkRunID: String
    public let checkName: String
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let level: AnnotationLevel
    public let message: String
    public let rawDetails: String?

    public enum AnnotationLevel: String, Equatable, Sendable, Decodable {
        case failure, warning, notice
    }

    public static func == (lhs: CheckAnnotation, rhs: CheckAnnotation) -> Bool {
        lhs.checkRunID == rhs.checkRunID &&
        lhs.checkName == rhs.checkName &&
        lhs.path == rhs.path &&
        lhs.startLine == rhs.startLine &&
        lhs.endLine == rhs.endLine &&
        lhs.level == rhs.level &&
        lhs.message == rhs.message &&
        lhs.rawDetails == rhs.rawDetails
    }

    public init(checkRunID: String, checkName: String, path: String, startLine: Int, endLine: Int, level: AnnotationLevel, message: String, rawDetails: String?) {
        self.checkRunID = checkRunID
        self.checkName = checkName
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.level = level
        self.message = message
        self.rawDetails = rawDetails
    }
}

/// Whether a review comment's author may steer the PR shepherd. Only
/// `trusted` comments trigger automatic fixes; `unknown` means the provider
/// could not classify the author and is treated like `untrusted`.
public enum ReviewAuthorTrust: String, Codable, Equatable, Sendable {
    case trusted
    case untrusted
    case unknown
}

public struct ReviewComment: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String?
    public let body: String
    public let url: URL?
    public let createdAt: Date?
    public let viewerCanUpdate: Bool
    public let viewerCanDelete: Bool
    public let isPending: Bool
    public let authorTrust: ReviewAuthorTrust
    /// True when the authenticated user wrote the comment, e.g. the agent
    /// replying through the user's CLI login.
    public let viewerDidAuthor: Bool

    public init(
        id: String,
        author: String?,
        body: String,
        url: URL?,
        createdAt: Date?,
        viewerCanUpdate: Bool,
        viewerCanDelete: Bool,
        isPending: Bool,
        authorTrust: ReviewAuthorTrust = .unknown,
        viewerDidAuthor: Bool = false
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.url = url
        self.createdAt = createdAt
        self.viewerCanUpdate = viewerCanUpdate
        self.viewerCanDelete = viewerCanDelete
        self.isPending = isPending
        self.authorTrust = authorTrust
        self.viewerDidAuthor = viewerDidAuthor
    }
}

public enum ReviewThreadSide: String, Codable, Equatable, Sendable {
    case old
    case new
    case unknown
}

public struct ReviewThreadLocation: Codable, Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let line: Int?
    public let side: ReviewThreadSide
    public let providerPosition: String?

    public init(path: String, originalPath: String?, line: Int?, side: ReviewThreadSide, providerPosition: String?) {
        self.path = path
        self.originalPath = originalPath
        self.line = line
        self.side = side
        self.providerPosition = providerPosition
    }
}

public struct ReviewThreadSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String?
    public let body: String
    public let url: URL?
    public let isResolved: Bool
    public let isActionable: Bool
    public let location: ReviewThreadLocation?
    public let providerThreadID: String?
    public let providerCommentID: String?

    public init(
        id: String,
        author: String?,
        body: String,
        url: URL?,
        isResolved: Bool,
        isActionable: Bool,
        location: ReviewThreadLocation? = nil,
        providerThreadID: String? = nil,
        providerCommentID: String? = nil
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.url = url
        self.isResolved = isResolved
        self.isActionable = isActionable
        self.location = location
        self.providerThreadID = providerThreadID
        self.providerCommentID = providerCommentID
    }
}

public struct ReviewThread: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String?
    public let line: Int?
    public let startLine: Int?
    public let originalLine: Int?
    public let originalStartLine: Int?
    public let diffHunk: String?
    public let diffSide: String?
    public let isResolved: Bool
    public let isOutdated: Bool
    public let isFileLevel: Bool
    public let comments: [ReviewComment]
    public let viewerCanResolve: Bool
    public let viewerCanUnresolve: Bool
    public let viewerCanReply: Bool
    public let url: URL?

    public init(
        id: String,
        path: String?,
        line: Int?,
        startLine: Int?,
        originalLine: Int?,
        originalStartLine: Int? = nil,
        diffHunk: String?,
        diffSide: String? = nil,
        isResolved: Bool,
        isOutdated: Bool,
        isFileLevel: Bool,
        comments: [ReviewComment],
        viewerCanResolve: Bool,
        viewerCanUnresolve: Bool? = nil,
        viewerCanReply: Bool,
        url: URL?
    ) {
        self.id = id
        self.path = path
        self.line = line
        self.startLine = startLine
        self.originalLine = originalLine
        self.originalStartLine = originalStartLine
        self.diffHunk = diffHunk
        self.diffSide = diffSide
        self.isResolved = isResolved
        self.isOutdated = isOutdated
        self.isFileLevel = isFileLevel
        self.comments = comments
        self.viewerCanResolve = viewerCanResolve
        self.viewerCanUnresolve = viewerCanUnresolve ?? viewerCanResolve
        self.viewerCanReply = viewerCanReply
        self.url = url
    }

    private var headComment: ReviewComment? {
        comments.first { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var author: String? { headComment?.author }
    public var body: String { headComment?.body ?? "" }
    public var headAuthorTrust: ReviewAuthorTrust { headComment?.authorTrust ?? .unknown }

    public var isActionable: Bool { !isResolved && !isOutdated }

    public func rangeStartLine(isOldSide: Bool) -> Int? {
        isOldSide ? originalStartLine : startLine
    }

    public func addingReply(_ comment: ReviewComment) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, startLine: startLine,
            originalLine: originalLine, originalStartLine: originalStartLine,
            diffHunk: diffHunk, diffSide: diffSide,
            isResolved: isResolved, isOutdated: isOutdated, isFileLevel: isFileLevel,
            comments: comments + [comment],
            viewerCanResolve: viewerCanResolve, viewerCanUnresolve: viewerCanUnresolve,
            viewerCanReply: viewerCanReply, url: url
        )
    }

    public func withResolved(_ resolved: Bool) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, startLine: startLine,
            originalLine: originalLine, originalStartLine: originalStartLine,
            diffHunk: diffHunk, diffSide: diffSide,
            isResolved: resolved, isOutdated: isOutdated, isFileLevel: isFileLevel,
            comments: comments,
            viewerCanResolve: viewerCanResolve, viewerCanUnresolve: viewerCanUnresolve,
            viewerCanReply: viewerCanReply, url: url
        )
    }

    public func replacingComment(id commentID: String, with replacement: ReviewComment) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, startLine: startLine,
            originalLine: originalLine, originalStartLine: originalStartLine,
            diffHunk: diffHunk, diffSide: diffSide,
            isResolved: isResolved, isOutdated: isOutdated, isFileLevel: isFileLevel,
            comments: comments.map { $0.id == commentID ? replacement : $0 },
            viewerCanResolve: viewerCanResolve, viewerCanUnresolve: viewerCanUnresolve,
            viewerCanReply: viewerCanReply, url: url
        )
    }

    public func removingComment(id commentID: String) -> ReviewThread {
        ReviewThread(
            id: id, path: path, line: line, startLine: startLine,
            originalLine: originalLine, originalStartLine: originalStartLine,
            diffHunk: diffHunk, diffSide: diffSide,
            isResolved: isResolved, isOutdated: isOutdated, isFileLevel: isFileLevel,
            comments: comments.filter { $0.id != commentID },
            viewerCanResolve: viewerCanResolve, viewerCanUnresolve: viewerCanUnresolve,
            viewerCanReply: viewerCanReply, url: url
        )
    }
}

public struct ReviewRequest: Identifiable, Equatable, Sendable {
    public var id: String { "\(provider.rawValue)-\(remote.host)-\(remote.repositorySlug)-\(number)" }
    public let remote: CodeHostRemote
    public let number: Int
    public let title: String
    public let url: URL
    public let state: ReviewRequestState
    public let isDraft: Bool
    public let headRefName: String
    public let baseRefName: String
    public let baseSHA: String?
    public let headSHA: String?
    /// Owner/namespace and name of the repository the head branch lives in.
    /// Differ from `remote` for forked pull requests — including same-owner
    /// forks, where only the name differs. Both are compared before remote-
    /// branch cleanup so a same-named branch in the base repo is never deleted.
    public let headRepositoryOwner: String?
    public let headRepositoryName: String?
    public let reviewDecision: ReviewDecision
    public let mergeState: ReviewMergeState
    public let checks: [ReviewCheck]
    public let threads: [ReviewThread]
    /// False when loading review threads/discussions failed, so `threads` may
    /// be missing actionable feedback. The merge gate fails closed on this: we
    /// must not offer merge while we can't confirm there are no open threads.
    public let areThreadsComplete: Bool
    public let isMergeQueueEnabled: Bool
    public let isInMergeQueue: Bool

    public var provider: CodeHostKind { remote.kind }

    public var displayIdentity: String { "\(provider.displayName) \(provider.reviewRequestNumberPrefix)\(number)" }

    public var headRepositorySlug: String? {
        guard let owner = headRepositoryOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
              let name = headRepositoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !owner.isEmpty,
              !name.isEmpty
        else { return nil }
        return "\(owner)/\(name)"
    }

    public init(
        remote: CodeHostRemote,
        number: Int,
        title: String,
        url: URL,
        state: ReviewRequestState,
        isDraft: Bool,
        headRefName: String,
        baseRefName: String,
        baseSHA: String? = nil,
        headSHA: String? = nil,
        headRepositoryOwner: String? = nil,
        headRepositoryName: String? = nil,
        reviewDecision: ReviewDecision,
        mergeState: ReviewMergeState,
        checks: [ReviewCheck],
        threads: [ReviewThread],
        areThreadsComplete: Bool = true,
        isMergeQueueEnabled: Bool = false,
        isInMergeQueue: Bool = false
    ) {
        self.remote = remote
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.headRepositoryOwner = headRepositoryOwner
        self.headRepositoryName = headRepositoryName
        self.reviewDecision = reviewDecision
        self.mergeState = mergeState
        self.checks = checks
        self.threads = threads
        self.areThreadsComplete = areThreadsComplete
        self.isMergeQueueEnabled = isMergeQueueEnabled
        self.isInMergeQueue = isInMergeQueue
    }

    public var worstCheckBucket: ReviewCheckBucket? {
        checks.max { $0.bucket.severity < $1.bucket.severity }?.bucket
    }

    public var hasActionableFeedback: Bool {
        reviewDecision == .changesRequested || threads.contains { $0.isActionable }
    }

    /// Returns a copy with `checks` replaced, preserving every other field.
    /// Used by the refresh path to attach freshly-fetched checks without
    /// dropping metadata like `headSHA`/`headRepositoryOwner` that the merge
    /// path relies on.
    public func withChecks(_ checks: [ReviewCheck]) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: number,
            title: title,
            url: url,
            state: state,
            isDraft: isDraft,
            headRefName: headRefName,
            baseRefName: baseRefName,
            baseSHA: baseSHA,
            headSHA: headSHA,
            headRepositoryOwner: headRepositoryOwner,
            headRepositoryName: headRepositoryName,
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            threads: threads,
            areThreadsComplete: areThreadsComplete,
            isMergeQueueEnabled: isMergeQueueEnabled,
            isInMergeQueue: isInMergeQueue
        )
    }

    /// Returns a copy with `threads` replaced, preserving every other field.
    /// Same rationale as `withChecks`: a hand-rolled copy in the provider used
    /// to silently drop `headRepositoryOwner`. `complete` records whether the
    /// thread fetch succeeded so the merge gate can fail closed on a failure.
    public func withThreads(_ threads: [ReviewThread], complete: Bool = true) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: number,
            title: title,
            url: url,
            state: state,
            isDraft: isDraft,
            headRefName: headRefName,
            baseRefName: baseRefName,
            baseSHA: baseSHA,
            headSHA: headSHA,
            headRepositoryOwner: headRepositoryOwner,
            headRepositoryName: headRepositoryName,
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            threads: threads,
            areThreadsComplete: complete,
            isMergeQueueEnabled: isMergeQueueEnabled,
            isInMergeQueue: isInMergeQueue
        )
    }

    public func withMergeQueue(isEnabled: Bool, isInQueue: Bool) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: number,
            title: title,
            url: url,
            state: state,
            isDraft: isDraft,
            headRefName: headRefName,
            baseRefName: baseRefName,
            baseSHA: baseSHA,
            headSHA: headSHA,
            headRepositoryOwner: headRepositoryOwner,
            headRepositoryName: headRepositoryName,
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            threads: threads,
            areThreadsComplete: areThreadsComplete,
            isMergeQueueEnabled: isEnabled,
            isInMergeQueue: isInQueue
        )
    }

    public static func placeholder(remote: CodeHostRemote, number: Int) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: number,
            title: "",
            url: remote.reviewRequestURL(number: number),
            state: .open,
            isDraft: false,
            headRefName: "",
            baseRefName: "",
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: [],
            threads: []
        )
    }
}

public struct ReviewLoopLocalState: Equatable, Sendable {
    public let branchName: String
    public let headSHA: String
    public let baseBranch: String
    public let hasWorkingTreeChanges: Bool
    public let hasStagedChanges: Bool
    public let aheadCommitCount: Int
    public let hasUpstream: Bool
    public let upstreamRemoteName: String?
    public let upstreamBranchName: String?
    public let headRemoteName: String?
    public let headRemoteOwner: String?
    public let upstreamAheadCommitCount: Int
    public let needsPush: Bool

    public init(
        branchName: String,
        headSHA: String,
        baseBranch: String,
        hasWorkingTreeChanges: Bool,
        hasStagedChanges: Bool,
        aheadCommitCount: Int,
        hasUpstream: Bool,
        upstreamRemoteName: String? = nil,
        upstreamBranchName: String? = nil,
        headRemoteName: String? = nil,
        headRemoteOwner: String? = nil,
        needsPush: Bool
    ) {
        self.init(
            branchName: branchName,
            headSHA: headSHA,
            baseBranch: baseBranch,
            hasWorkingTreeChanges: hasWorkingTreeChanges,
            hasStagedChanges: hasStagedChanges,
            aheadCommitCount: aheadCommitCount,
            hasUpstream: hasUpstream,
            upstreamRemoteName: upstreamRemoteName,
            upstreamBranchName: upstreamBranchName,
            headRemoteName: headRemoteName,
            headRemoteOwner: headRemoteOwner,
            upstreamAheadCommitCount: 0,
            needsPush: needsPush
        )
    }

    public init(
        branchName: String,
        headSHA: String,
        baseBranch: String,
        hasWorkingTreeChanges: Bool,
        hasStagedChanges: Bool,
        aheadCommitCount: Int,
        hasUpstream: Bool,
        upstreamRemoteName: String? = nil,
        upstreamBranchName: String? = nil,
        headRemoteName: String? = nil,
        headRemoteOwner: String? = nil,
        upstreamAheadCommitCount: Int,
        needsPush: Bool
    ) {
        self.branchName = branchName
        self.headSHA = headSHA
        self.baseBranch = baseBranch
        self.hasWorkingTreeChanges = hasWorkingTreeChanges
        self.hasStagedChanges = hasStagedChanges
        self.aheadCommitCount = aheadCommitCount
        self.hasUpstream = hasUpstream
        self.upstreamRemoteName = upstreamRemoteName
        self.upstreamBranchName = upstreamBranchName
        self.headRemoteName = headRemoteName
        self.headRemoteOwner = headRemoteOwner
        self.upstreamAheadCommitCount = upstreamAheadCommitCount
        self.needsPush = needsPush
    }

    public var pushState: ReviewLoopPushState {
        if !hasUpstream { return .missingUpstream }
        if needsPush, upstreamAheadCommitCount > 0 { return .diverged }
        if upstreamAheadCommitCount > 0 { return .stale }
        if needsPush { return .unpushed }
        return .inSync
    }
}

public enum ReviewLoopPushState: Equatable, Sendable {
    case inSync
    case missingUpstream
    case unpushed
    case diverged
    case stale
}

public struct ReviewLoopSnapshot: Equatable, Sendable {
    public let local: ReviewLoopLocalState
    public let remote: CodeHostRemote?
    public let reviewRequest: ReviewRequest?
    public let providerAvailable: Bool
    public let providerAuthenticated: Bool
    public let providerCapabilities: CodeHostProviderCapabilities
    public let errorMessage: String?

    public init(local: ReviewLoopLocalState, remote: CodeHostRemote?, reviewRequest: ReviewRequest?, providerAvailable: Bool, providerAuthenticated: Bool, providerCapabilities: CodeHostProviderCapabilities, errorMessage: String?) {
        self.local = local
        self.remote = remote
        self.reviewRequest = reviewRequest
        self.providerAvailable = providerAvailable
        self.providerAuthenticated = providerAuthenticated
        self.providerCapabilities = providerCapabilities
        self.errorMessage = errorMessage
    }
}

extension ReviewLoopSnapshot {
    public func pushArguments(forceWithLease: Bool) -> [String] {
        var args = ["push"]
        if forceWithLease {
            args.append("--force-with-lease")
        }
        let remoteName = local.upstreamRemoteName
            ?? local.headRemoteName
            ?? remote?.remoteName
            ?? "origin"
        let pushRef = local.upstreamBranchName.map { "HEAD:\($0)" } ?? local.branchName
        args.append(contentsOf: ["-u", remoteName, pushRef])
        return args
    }
}

public enum ReviewLoopActionKind: String, Codable, Equatable, Sendable {
    case prepareCheckFailureHandoff
    case prepareReviewHandoff
}

public struct ReviewLoopAction: Equatable, Sendable {
    public let kind: ReviewLoopActionKind
    public let title: String
    public let detail: String

    public init(kind: ReviewLoopActionKind, title: String, detail: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

extension CodeHostKind {
    public func mergeReviewRequestTitle(for request: ReviewRequest) -> String {
        if request.isMergeQueueEnabled { return "Add to queue" }
        return mergeReviewRequestTitle
    }
}

// A review status crosses the host protocol to paired Macs.
extension CodeHostProviderCapabilities: Codable {}
extension ReviewCheck: Codable {}
extension ReviewComment: Codable {}
extension ReviewThread: Codable {}
extension ReviewRequest: Codable {}
extension ReviewLoopLocalState: Codable {}

extension ReviewLoopSnapshot: Codable {
    /// A newer host's code host, pull request or capabilities that this
    /// side can't read decode as none, keeping the branch state.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            local: c.decode(ReviewLoopLocalState.self, forKey: .local),
            remote: (try? c.decodeIfPresent(CodeHostRemote.self, forKey: .remote)) ?? nil,
            reviewRequest: (try? c.decodeIfPresent(ReviewRequest.self, forKey: .reviewRequest)) ?? nil,
            providerAvailable: c.decode(Bool.self, forKey: .providerAvailable),
            providerAuthenticated: c.decode(Bool.self, forKey: .providerAuthenticated),
            providerCapabilities: (try? c.decode(CodeHostProviderCapabilities.self, forKey: .providerCapabilities)) ?? .readOnly,
            errorMessage: c.decodeIfPresent(String.self, forKey: .errorMessage)
        )
    }
}

extension ReviewSessionTarget {
    /// The remote a pull or merge request review loads from; nil for other kinds.
    public var providerRemote: CodeHostRemote? {
        guard case .reviewRequest(let kind, let host, let repositorySlug, _, _) = payload,
              let separator = repositorySlug.lastIndex(of: "/")
        else { return nil }
        let owner = String(repositorySlug[..<separator])
        let repository = String(repositorySlug[repositorySlug.index(after: separator)...])
        guard !owner.isEmpty, !repository.isEmpty,
              let webURL = providerURL ?? URL(string: "https://\(host)/\(repositorySlug)")
        else { return nil }
        return CodeHostRemote(kind: kind, host: host, owner: owner, repository: repository, remoteName: "origin", webURL: webURL)
    }
}

extension ReviewRequest {
    /// This request at `headSHA`; itself when nil.
    public func pinned(headSHA: String?) -> ReviewRequest {
        guard let headSHA else { return self }
        return ReviewRequest(
            remote: remote, number: number, title: title, url: url, state: state, isDraft: isDraft,
            headRefName: headRefName, baseRefName: baseRefName, baseSHA: baseSHA, headSHA: headSHA,
            headRepositoryOwner: headRepositoryOwner, headRepositoryName: headRepositoryName,
            reviewDecision: reviewDecision, mergeState: mergeState, checks: checks, threads: threads,
            areThreadsComplete: areThreadsComplete, isMergeQueueEnabled: isMergeQueueEnabled, isInMergeQueue: isInMergeQueue
        )
    }
}
