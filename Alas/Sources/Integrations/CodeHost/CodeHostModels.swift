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
}

struct CodeHostRemote: Equatable, Sendable {
    let kind: CodeHostKind
    let host: String
    let owner: String
    let repository: String
    let remoteName: String
    let webURL: URL

    var repositorySlug: String { "\(owner)/\(repository)" }
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
        canDeleteComment: false
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
        canDeleteComment: true
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
        canDeleteComment: true
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

struct ReviewThread: Identifiable, Equatable, Sendable {
    let id: String
    let path: String?
    let line: Int?
    let startLine: Int?
    let originalLine: Int?
    let diffHunk: String?
    let isResolved: Bool
    let isOutdated: Bool
    let isFileLevel: Bool
    let comments: [ReviewComment]
    let viewerCanResolve: Bool
    let viewerCanReply: Bool
    let url: URL?

    private var headComment: ReviewComment? {
        comments.first { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var author: String? { headComment?.author }
    var body: String { headComment?.body ?? "" }

    var isActionable: Bool { !isResolved && !isOutdated }
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
    let headSHA: String?
    let reviewDecision: ReviewDecision
    let mergeState: ReviewMergeState
    let checks: [ReviewCheck]
    let threads: [ReviewThread]

    var provider: CodeHostKind { remote.kind }

    var displayIdentity: String { "\(provider.displayName) \(provider.reviewRequestNumberPrefix)\(number)" }

    init(
        remote: CodeHostRemote,
        number: Int,
        title: String,
        url: URL,
        state: ReviewRequestState,
        isDraft: Bool,
        headRefName: String,
        baseRefName: String,
        headSHA: String? = nil,
        reviewDecision: ReviewDecision,
        mergeState: ReviewMergeState,
        checks: [ReviewCheck],
        threads: [ReviewThreadSummary]
    ) {
        self.remote = remote
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.headSHA = headSHA
        self.reviewDecision = reviewDecision
        self.mergeState = mergeState
        self.checks = checks
        self.threads = threads
    }

    var worstCheckBucket: ReviewCheckBucket? {
        checks.max { $0.bucket.severity < $1.bucket.severity }?.bucket
    }

    var hasActionableFeedback: Bool {
        reviewDecision == .changesRequested || threads.contains { $0.isActionable }
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
