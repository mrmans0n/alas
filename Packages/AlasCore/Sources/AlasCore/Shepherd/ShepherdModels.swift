import Foundation

/// Identity of one shepherded review request. v1 excludes Workspace
/// checkouts, so the owner is always the worktree (`SessionOwnerID` is not
/// Codable, which is why it isn't stored here).
public struct ShepherdRecordID: Hashable, Codable, Sendable {
    public let worktreeID: String
    public let providerKind: CodeHostKind
    public let host: String
    public let repositorySlug: String
    public let requestNumber: Int

    public init(worktreeID: String, providerKind: CodeHostKind, host: String, repositorySlug: String, requestNumber: Int) {
        self.worktreeID = worktreeID
        self.providerKind = providerKind
        self.host = host
        self.repositorySlug = repositorySlug
        self.requestNumber = requestNumber
    }

    public init(worktreeID: String, request: ReviewRequest) {
        self.init(
            worktreeID: worktreeID,
            providerKind: request.provider,
            host: request.remote.host,
            repositorySlug: request.remote.repositorySlug,
            requestNumber: request.number
        )
    }

    public var storageKey: String {
        "\(worktreeID)|\(providerKind.rawValue)|\(host)|\(repositorySlug)|\(requestNumber)"
    }
}

public enum ShepherdEscalation: String, Codable, Equatable, Sendable {
    case attemptsExhausted, noProgress, deliveryFailed, ownerGone, authFailed
}

public enum ShepherdOutcome: String, Codable, Equatable, Sendable {
    case merged, closed
}

public enum ShepherdPhase: Codable, Equatable, Sendable {
    case watching
    /// Prompt delivered; the turn is queued or running.
    case fixing(dispatchedAt: Date)
    case awaitingPush(turnEndedAt: Date, pollsWithoutProgress: Int)
    case merging
    /// In a merge queue; polling continues until the provider reports merged.
    case queued
    case escalated(ShepherdEscalation)
    /// Provider auth failed; resumes on the next successful fetch.
    case paused
    case merged
    case closed

    public var isTerminal: Bool {
        switch self {
        case .merged, .closed: true
        default: false
        }
    }
}

public struct ShepherdFingerprint: Codable, Equatable, Sendable {
    public let headSHA: String
    public let hasConflict: Bool
    /// Sorted.
    public let failingCheckIDs: [String]
    /// Sorted `"<thread id>#<latest trusted comment id>"` entries for
    /// actionable threads from trusted reviewers only.
    public let threadIDs: [String]

    public init(headSHA: String, hasConflict: Bool, failingCheckIDs: [String], threadIDs: [String]) {
        self.headSHA = headSHA
        self.hasConflict = hasConflict
        self.failingCheckIDs = failingCheckIDs
        self.threadIDs = threadIDs
    }
}

public struct ShepherdRecord: Codable, Equatable, Sendable {
    public let id: ShepherdRecordID
    public var sessionID: String
    public var remote: CodeHostRemote
    public var branch: String
    public var baseBranch: String
    public var autoFix: Bool
    public var autoMerge: Bool
    public var phase: ShepherdPhase
    public var lastDispatchedFingerprint: ShepherdFingerprint?
    /// Sorted ids of the viewer's comments in the dispatched threads at
    /// dispatch time, so a later viewer comment reads as the agent's reply.
    /// Nil in records saved before this field existed. Cleared with the
    /// fingerprint.
    public var viewerCommentIDsAtDispatch: [String]?
    /// Sorted thread revisions (`"<thread id>#<latest trusted comment id>"`)
    /// the agent answered with a reply; they are not dispatched again until
    /// a trusted reviewer comments. Nil means none, including records saved
    /// before this field existed.
    public var handledThreadRevisions: [String]?
    public var fixAttempts: Int
    public var lastSeenHeadSHA: String?
    /// Consecutive polls that saw `lastSeenHeadSHA` with no pending or
    /// unknown check,
    /// capped at `ShepherdPolicy.requiredStablePolls`.
    public var stableHeadPolls: Int
    public var notifiedReadyHeadSHA: String?
    public var finishedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ShepherdRecordID,
        sessionID: String,
        remote: CodeHostRemote,
        branch: String,
        baseBranch: String,
        autoFix: Bool,
        autoMerge: Bool,
        now: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.remote = remote
        self.branch = branch
        self.baseBranch = baseBranch
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.phase = .watching
        self.lastDispatchedFingerprint = nil
        self.viewerCommentIDsAtDispatch = nil
        self.handledThreadRevisions = nil
        self.fixAttempts = 0
        self.lastSeenHeadSHA = nil
        self.stableHeadPolls = 0
        self.notifiedReadyHeadSHA = nil
        self.finishedAt = nil
        self.createdAt = now
        self.updatedAt = now
    }

    public var owner: SessionOwnerID { .worktree(id.worktreeID) }
}

public enum ShepherdSessionState: Equatable, Sendable {
    case idle, busy, archived, missing
}

/// Global defaults for newly bound PRs (`AppConfig.Changes.shepherd`).
public struct ShepherdDefaults: Codable, Equatable, Sendable {
    public var autoFix: Bool = true
    public var autoMerge: Bool = false
    public var archiveAfterMerge: Bool = false

    private enum CodingKeys: String, CodingKey {
        case autoFix, autoMerge, archiveAfterMerge
    }

    public init(autoFix: Bool = true, autoMerge: Bool = false, archiveAfterMerge: Bool = false) {
        self.autoFix = autoFix
        self.autoMerge = autoMerge
        self.archiveAfterMerge = archiveAfterMerge
    }

    /// Tolerant, like the rest of `AppConfig`: a missing or mistyped key keeps
    /// its default instead of failing the whole config.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoFix = (try? c.decode(Bool.self, forKey: .autoFix)) ?? true
        autoMerge = (try? c.decode(Bool.self, forKey: .autoMerge)) ?? false
        archiveAfterMerge = (try? c.decode(Bool.self, forKey: .archiveAfterMerge)) ?? false
    }
}
