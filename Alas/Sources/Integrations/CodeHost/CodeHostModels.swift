import Foundation

enum CodeHostKind: String, Codable, Equatable, Sendable {
    case github
    case gitlab

    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        }
    }

    var reviewRequestLabel: String {
        switch self {
        case .github: "PR"
        case .gitlab: "MR"
        }
    }

    var reviewRequestNumberPrefix: String {
        switch self {
        case .github: "#"
        case .gitlab: "!"
        }
    }

    var iconName: String {
        switch self {
        case .github: "github"
        case .gitlab: "gitlab"
        }
    }

    var createReviewRequestTitle: String {
        "Create \(reviewRequestLabel)"
    }

    var openReviewRequestTitle: String {
        "Open \(reviewRequestLabel)"
    }

    var mergeReviewRequestTitle: String {
        "Merge \(reviewRequestLabel)"
    }

    func mergeReviewRequestTitle(for request: ReviewRequest) -> String {
        if request.isMergeQueueEnabled { return "Add to queue" }
        return mergeReviewRequestTitle
    }
}

struct CodeHostRemote: Equatable, Sendable {
    let kind: CodeHostKind
    let host: String
    let owner: String
    let repository: String
    let remoteName: String
    let webURL: URL

    var repositorySlug: String { "\(owner)/\(repository)" }

    func commitURL(sha: String) -> URL {
        switch kind {
        case .github:
            return webURL.appendingPathComponent("commit").appendingPathComponent(sha)
        case .gitlab:
            return webURL.appendingPathComponent("-").appendingPathComponent("commit").appendingPathComponent(sha)
        }
    }

    func reviewRequestURL(number: Int) -> URL {
        switch kind {
        case .github:
            return webURL.appendingPathComponent("pull").appendingPathComponent("\(number)")
        case .gitlab:
            return webURL.appendingPathComponent("-")
                .appendingPathComponent("merge_requests").appendingPathComponent("\(number)")
        }
    }
}

struct CodeHostProviderCapabilities: Equatable, Sendable {
    let canCreateReviewRequest: Bool
    let canRerunFailedChecks: Bool
    let canOpenReviewRequest: Bool
    let canReply: Bool
    let canResolve: Bool
    let canComment: Bool
    let canSubmitReview: Bool
    let canFetchAnnotations: Bool
    let canEditComment: Bool
    let canDeleteComment: Bool
    let canMerge: Bool

    static let readOnly = CodeHostProviderCapabilities(
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

    static let githubCLI = CodeHostProviderCapabilities(
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

    static let gitlabCLI = CodeHostProviderCapabilities(
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
}

enum ReviewVerdict: String, Codable, Equatable, Sendable {
    case approve
    case requestChanges
    case comment
}

enum ReviewRequestState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case merged
}

enum ReviewDecision: String, Codable, Equatable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
    case unknown
}

enum ReviewMergeState: String, Codable, Equatable, Sendable {
    case clean
    case blocked
    case dirty
    case unstable
    case unknown
}

enum ReviewMergeMethod: String, Codable, Equatable, Sendable {
    case squash
    case merge
    case rebase
}

enum ReviewCheckBucket: String, Codable, Equatable, Sendable {
    case pass
    case fail
    case pending
    case skipping
    case cancel
    case unknown

    var severity: Int {
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

struct ReviewCheck: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let workflow: String?
    let bucket: ReviewCheckBucket
    let detailURL: URL?
    let completedAt: Date?
}

struct CheckAnnotation: Identifiable, Equatable, Sendable {
    var id: String { "\(checkRunID)-\(path)-\(startLine)-\(endLine)-\(level.rawValue)-\(message.hashValue)" }
    let checkRunID: String
    let checkName: String
    let path: String
    let startLine: Int
    let endLine: Int
    let level: AnnotationLevel
    let message: String
    let rawDetails: String?

    enum AnnotationLevel: String, Equatable, Sendable, Decodable {
        case failure, warning, notice
    }

    static func == (lhs: CheckAnnotation, rhs: CheckAnnotation) -> Bool {
        lhs.checkRunID == rhs.checkRunID &&
        lhs.checkName == rhs.checkName &&
        lhs.path == rhs.path &&
        lhs.startLine == rhs.startLine &&
        lhs.endLine == rhs.endLine &&
        lhs.level == rhs.level &&
        lhs.message == rhs.message &&
        lhs.rawDetails == rhs.rawDetails
    }
}

struct ReviewComment: Identifiable, Equatable, Sendable {
    let id: String
    let author: String?
    let body: String
    let url: URL?
    let createdAt: Date?
    let viewerCanUpdate: Bool
    let viewerCanDelete: Bool
    let isPending: Bool
}

enum ReviewThreadSide: String, Codable, Equatable, Sendable {
    case old
    case new
    case unknown
}

struct ReviewThreadLocation: Codable, Equatable, Sendable {
    let path: String
    let originalPath: String?
    let line: Int?
    let side: ReviewThreadSide
    let providerPosition: String?
}

struct ReviewThreadSummary: Identifiable, Equatable, Sendable {
    let id: String
    let author: String?
    let body: String
    let url: URL?
    let isResolved: Bool
    let isActionable: Bool
    let location: ReviewThreadLocation?
    let providerThreadID: String?
    let providerCommentID: String?

    init(
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

struct ReviewThread: Identifiable, Equatable, Sendable {
    let id: String
    let path: String?
    let line: Int?
    let startLine: Int?
    let originalLine: Int?
    let originalStartLine: Int?
    let diffHunk: String?
    let diffSide: String?
    let isResolved: Bool
    let isOutdated: Bool
    let isFileLevel: Bool
    let comments: [ReviewComment]
    let viewerCanResolve: Bool
    let viewerCanUnresolve: Bool
    let viewerCanReply: Bool
    let url: URL?

    init(
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

    var author: String? { headComment?.author }
    var body: String { headComment?.body ?? "" }

    var isActionable: Bool { !isResolved && !isOutdated }

    func rangeStartLine(isOldSide: Bool) -> Int? {
        isOldSide ? originalStartLine : startLine
    }

    func addingReply(_ comment: ReviewComment) -> ReviewThread {
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

    func withResolved(_ resolved: Bool) -> ReviewThread {
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

    func replacingComment(id commentID: String, with replacement: ReviewComment) -> ReviewThread {
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

    func removingComment(id commentID: String) -> ReviewThread {
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

struct ReviewRequest: Identifiable, Equatable, Sendable {
    var id: String { "\(provider.rawValue)-\(remote.host)-\(remote.repositorySlug)-\(number)" }
    let remote: CodeHostRemote
    let number: Int
    let title: String
    let url: URL
    let state: ReviewRequestState
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String
    let baseSHA: String?
    let headSHA: String?
    /// Owner/namespace and name of the repository the head branch lives in.
    /// Differ from `remote` for forked pull requests — including same-owner
    /// forks, where only the name differs. Both are compared before remote-
    /// branch cleanup so a same-named branch in the base repo is never deleted.
    let headRepositoryOwner: String?
    let headRepositoryName: String?
    let reviewDecision: ReviewDecision
    let mergeState: ReviewMergeState
    let checks: [ReviewCheck]
    let threads: [ReviewThread]
    /// False when loading review threads/discussions failed, so `threads` may
    /// be missing actionable feedback. The merge gate fails closed on this: we
    /// must not offer merge while we can't confirm there are no open threads.
    let areThreadsComplete: Bool
    let isMergeQueueEnabled: Bool
    let isInMergeQueue: Bool

    var provider: CodeHostKind { remote.kind }

    var displayIdentity: String { "\(provider.displayName) \(provider.reviewRequestNumberPrefix)\(number)" }

    var headRepositorySlug: String? {
        guard let owner = headRepositoryOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
              let name = headRepositoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !owner.isEmpty,
              !name.isEmpty
        else { return nil }
        return "\(owner)/\(name)"
    }

    init(
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

    var worstCheckBucket: ReviewCheckBucket? {
        checks.max { $0.bucket.severity < $1.bucket.severity }?.bucket
    }

    var hasActionableFeedback: Bool {
        reviewDecision == .changesRequested || threads.contains { $0.isActionable }
    }

    /// Returns a copy with `checks` replaced, preserving every other field.
    /// Used by the refresh path to attach freshly-fetched checks without
    /// dropping metadata like `headSHA`/`headRepositoryOwner` that the merge
    /// path relies on.
    func withChecks(_ checks: [ReviewCheck]) -> ReviewRequest {
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
    func withThreads(_ threads: [ReviewThread], complete: Bool = true) -> ReviewRequest {
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

    func withMergeQueue(isEnabled: Bool, isInQueue: Bool) -> ReviewRequest {
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

    static func placeholder(remote: CodeHostRemote, number: Int) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: number,
            title: "",
            url: remote.webURL,
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

struct ReviewLoopLocalState: Equatable, Sendable {
    let branchName: String
    let headSHA: String
    let baseBranch: String
    let hasWorkingTreeChanges: Bool
    let hasStagedChanges: Bool
    let aheadCommitCount: Int
    let hasUpstream: Bool
    let upstreamRemoteName: String?
    let upstreamBranchName: String?
    let headRemoteName: String?
    let headRemoteOwner: String?
    let upstreamAheadCommitCount: Int
    let needsPush: Bool

    init(
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

    init(
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

    var pushState: ReviewLoopPushState {
        if !hasUpstream { return .missingUpstream }
        if needsPush, upstreamAheadCommitCount > 0 { return .diverged }
        if upstreamAheadCommitCount > 0 { return .stale }
        if needsPush { return .unpushed }
        return .inSync
    }
}

enum ReviewLoopPushState: Equatable, Sendable {
    case inSync
    case missingUpstream
    case unpushed
    case diverged
    case stale
}

struct ReviewLoopSnapshot: Equatable, Sendable {
    let local: ReviewLoopLocalState
    let remote: CodeHostRemote?
    let reviewRequest: ReviewRequest?
    let providerAvailable: Bool
    let providerAuthenticated: Bool
    let providerCapabilities: CodeHostProviderCapabilities
    let errorMessage: String?
}

enum ReviewLoopActionKind: String, Codable, Equatable, Sendable {
    case prepareCheckFailureHandoff
    case prepareReviewHandoff
}

struct ReviewLoopAction: Equatable, Sendable {
    let kind: ReviewLoopActionKind
    let title: String
    let detail: String
}
