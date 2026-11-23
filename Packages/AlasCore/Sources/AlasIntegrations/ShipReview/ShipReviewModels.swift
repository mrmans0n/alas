import Foundation
import AlasModel

/// A ship review is keyed by worktree and owning session, so the record
/// found before the PR exists is the one the shepherd finds after.
public struct ShipReviewID: Hashable, Codable, Sendable {
    public let worktreeID: String
    public let sessionID: String

    public init(worktreeID: String, sessionID: String) {
        self.worktreeID = worktreeID
        self.sessionID = sessionID
    }
}

/// The `pr_create` request a review holds back until the head passes.
public struct PendingPRPush: Codable, Equatable, Sendable {
    public var title: String
    public var body: String
    public var draft: Bool
    public var base: String?

    public init(title: String, body: String, draft: Bool, base: String?) {
        self.title = title
        self.body = body
        self.draft = draft
        self.base = base
    }
}

/// What Alas pushes once the head passes.
public enum ShipReviewTarget: Codable, Equatable, Sendable {
    /// The first push and PR fix pushes (`pr_create` adopts the open PR).
    case pullRequest(PendingPRPush)
    /// `base` is the gg stack's base, which the review diffs against; nil
    /// in records written before it was kept.
    case stack(StackShipPlan, base: String?)
    /// A head already on the remote; a clean review just records it.
    case pushedHead
}

/// Why a ship review stopped. Nothing is pushed until the user acts.
public enum ShipReviewStop: Codable, Equatable, Sendable {
    case roundsExhausted(openFindings: Int)
    case findingsWithAutoFixOff(count: Int)
    case reviewerFailed(String)
    case instructionsUnreadable(String)
    case noProgress(openFindings: Int)
    case pushFailed(String)
}

public enum ShipReviewPhase: Codable, Equatable, Sendable {
    case idle
    case reviewing(headSHA: String, startedAt: Date)
    /// Findings were sent to the owning session.
    case awaitingFix(headSHA: String)
    case pushing(headSHA: String)
    case stopped(ShipReviewStop)
}

/// One reviewer pass over one head.
public struct ShipReviewRound: Codable, Equatable, Sendable {
    public var number: Int
    public var headSHA: String
    /// The review pane session the round's findings are filed in.
    public var reviewSessionID: ReviewSessionID?
    public var verdict: ReviewVerdict?
    public var summary: String?
    public var openFindingIDs: [String]
    /// Findings folded into the summary because their paths were outside
    /// the diff; nil in rounds recorded before this was tracked.
    public var unfiledFindings: Int?
    /// "Codex · gpt-5.2"
    public var reviewerLabel: String
    /// Nil until the reviewer's result is in.
    public var reviewedAt: Date?

    public init(
        number: Int,
        headSHA: String,
        reviewSessionID: ReviewSessionID? = nil,
        verdict: ReviewVerdict? = nil,
        summary: String? = nil,
        openFindingIDs: [String] = [],
        reviewerLabel: String = "",
        reviewedAt: Date? = nil
    ) {
        self.number = number
        self.headSHA = headSHA
        self.reviewSessionID = reviewSessionID
        self.verdict = verdict
        self.summary = summary
        self.openFindingIDs = openFindingIDs
        self.reviewerLabel = reviewerLabel
        self.reviewedAt = reviewedAt
    }

    /// `approve`, or `comment` with no open findings. `request_changes` never is.
    public var isClean: Bool {
        switch verdict {
        case .approve: true
        case .comment: openFindingIDs.isEmpty
        case .requestChanges, nil: false
        }
    }
}

/// Review before push for one owning session: the lever, the held-back
/// push, and the rounds that decide whether it goes out.
public struct ShipReviewRecord: Codable, Equatable, Sendable {
    public static let maxRoundsRange = 1...10
    public static let roundHistoryLimit = 30
    public static let passedSHALimit = 50

    public let id: ShipReviewID
    public var enabled: Bool
    /// Per-ship override; nil resolves through project and global settings.
    public var reviewer: ReviewerChoice?
    public var maxRounds: Int
    public var pending: ShipReviewTarget?
    public var phase: ShipReviewPhase
    /// Reviews with findings since the last push.
    public var roundsThisPush: Int
    /// Newest last, capped at `roundHistoryLimit`.
    public var rounds: [ShipReviewRound]
    /// Clean or allowed heads; newest last, capped at `passedSHALimit`.
    public var passedSHAs: [String]
    /// A remote head Alas can't review and nobody allowed yet.
    public var unreviewedRemoteHead: String?
    public var reviewerSessionID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: ShipReviewID, enabled: Bool, reviewer: ReviewerChoice?, maxRounds: Int, now: Date) {
        self.id = id
        self.enabled = enabled
        self.reviewer = reviewer
        self.maxRounds = min(max(maxRounds, Self.maxRoundsRange.lowerBound), Self.maxRoundsRange.upperBound)
        self.pending = nil
        self.phase = .idle
        self.roundsThisPush = 0
        self.rounds = []
        self.passedSHAs = []
        self.unreviewedRemoteHead = nil
        self.reviewerSessionID = nil
        self.createdAt = now
        self.updatedAt = now
    }

    public var currentRound: ShipReviewRound? { rounds.last }
}

/// What the coordinator does next.
public enum ShipReviewAction: Equatable, Sendable {
    case none
    case startRound(headSHA: String)
    case push(headSHA: String)
    case sendFindings(round: Int)
    case stop(ShipReviewStop)
}

public enum ShipReviewFailure: Error, Equatable, Sendable {
    case reviewer(String)
    case noResult
    case instructions(String)
}
