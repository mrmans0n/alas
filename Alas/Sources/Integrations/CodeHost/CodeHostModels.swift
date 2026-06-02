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

struct ReviewThreadSummary: Identifiable, Equatable, Sendable {
    let id: String
    let author: String?
    let body: String
    let url: URL?
    let isResolved: Bool
    let isActionable: Bool
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
    let reviewDecision: ReviewDecision
    let mergeState: ReviewMergeState
    let checks: [ReviewCheck]
    let threads: [ReviewThreadSummary]

    var provider: CodeHostKind { remote.kind }

    var displayIdentity: String { "\(provider.displayName) #\(number)" }

    var worstCheckBucket: ReviewCheckBucket? {
        checks.max { $0.bucket.severity < $1.bucket.severity }?.bucket
    }

    var hasActionableFeedback: Bool {
        reviewDecision == .changesRequested || threads.contains { !$0.isResolved && $0.isActionable }
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
    let needsPush: Bool
}

struct ReviewLoopSnapshot: Equatable, Sendable {
    let local: ReviewLoopLocalState
    let remote: CodeHostRemote?
    let reviewRequest: ReviewRequest?
    let providerAvailable: Bool
    let providerAuthenticated: Bool
    let errorMessage: String?
}

enum ReviewLoopActionKind: String, Codable, Equatable, Sendable {
    case installProviderCLI
    case authenticateProvider
    case startSession
    case pushBranch
    case createReviewRequest
    case updateReviewRequest
    case waitForChecks
    case prepareCheckFailureHandoff
    case prepareReviewHandoff
    case rerunFailedChecks
    case waitForReview
    case readyToMerge
    case blocked
    case none
}

struct ReviewLoopAction: Equatable, Sendable {
    let kind: ReviewLoopActionKind
    let title: String
    let detail: String

    var requiresSessionApproval: Bool {
        switch kind {
        case .pushBranch, .createReviewRequest, .updateReviewRequest, .rerunFailedChecks:
            true
        default:
            false
        }
    }

    var requiresExplicitConfirmation: Bool {
        switch kind {
        case .readyToMerge:
            true
        default:
            false
        }
    }
}
