import Foundation

/// The problems one fix turn is asked to address, ordered conflict, checks,
/// threads.
public struct ShepherdFixRequest: Equatable, Sendable {
    public let hasConflict: Bool
    public let failingChecks: [ReviewCheck]
    /// Actionable threads whose head comment is from a trusted reviewer.
    public let threads: [ReviewThread]

    public init(hasConflict: Bool, failingChecks: [ReviewCheck], threads: [ReviewThread]) {
        self.hasConflict = hasConflict
        self.failingChecks = failingChecks
        self.threads = threads
    }

    public var isEmpty: Bool { !hasConflict && failingChecks.isEmpty && threads.isEmpty }

    public func fingerprint(headSHA: String) -> ShepherdFingerprint {
        ShepherdFingerprint(
            headSHA: headSHA,
            hasConflict: hasConflict,
            failingCheckIDs: failingChecks.map(\.id).sorted(),
            threadIDs: threadRevisions
        )
    }

    /// Sorted `"<thread id>#<latest trusted comment id>"` entries, so a new
    /// trusted comment in a thread counts as new feedback.
    var threadRevisions: [String] {
        threads.map(Self.revision(of:)).sorted()
    }

    static func revision(of thread: ReviewThread) -> String {
        let latest = thread.comments.last { $0.authorTrust == .trusted }?.id ?? ""
        return "\(thread.id)#\(latest)"
    }
}

public enum ShepherdAction: Equatable, Sendable {
    case wait
    case dispatchFix(ShepherdFixRequest)
    case merge
    case notifyReady
    case finish(ShepherdOutcome)
    case escalate(ShepherdEscalation)
}

public struct ShepherdObservation: Equatable, Sendable {
    /// Has `local` and `reviewRequest`.
    public let snapshot: ReviewLoopSnapshot
    /// Nil when not fetched or the fetch failed; the gate then fails closed
    /// whenever the rules require reviewers.
    public let headReviewers: Set<String>?
    public let session: ShepherdSessionState
    public let rules: ShepherdRules
    public let now: Date

    public init(
        snapshot: ReviewLoopSnapshot,
        headReviewers: Set<String>?,
        session: ShepherdSessionState,
        rules: ShepherdRules,
        now: Date
    ) {
        self.snapshot = snapshot
        self.headReviewers = headReviewers
        self.session = session
        self.rules = rules
        self.now = now
    }
}

public struct ShepherdDecision: Equatable, Sendable {
    public let record: ShepherdRecord
    public let action: ShepherdAction

    public init(record: ShepherdRecord, action: ShepherdAction) {
        self.record = record
        self.action = action
    }
}

/// Pure decision logic for one shepherd poll. Runs only after a successful
/// provider fetch; fetch errors are the poller's business.
public enum ShepherdPolicy {
    public static let maxFixAttempts = 3
    public static let noProgressPollLimit = 3
    public static let requiredStablePolls = 2
    /// An awaitingPush record with no progress escalates after this long,
    /// even while inconclusive observations keep the poll counter still.
    public static let awaitingPushTimeout: TimeInterval = 2 * 60 * 60
    /// Clock skew allowed between the dispatch and the agent's reply.
    private static let replyClockSkew: TimeInterval = 60

    public static func decide(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> ShepherdDecision {
        guard !record.phase.isTerminal,
              let request = observation.snapshot.reviewRequest,
              request.number == record.id.requestNumber
        else { return ShepherdDecision(record: record, action: .wait) }

        var next = record
        let action = evaluate(&next, request: request, observation: observation)
        if next != record { next.updatedAt = observation.now }
        return ShepherdDecision(record: next, action: action)
    }

    public static func problems(in request: ReviewRequest) -> ShepherdFixRequest {
        ShepherdFixRequest(
            hasConflict: request.mergeState == .dirty,
            // Partial CI results never trigger a fix.
            failingChecks: hasIncompleteChecks(request) ? [] : request.checks.filter { $0.bucket == .fail },
            threads: request.threads.filter { $0.isActionable && $0.headAuthorTrust == .trusted }
        )
    }

    /// The existing readiness gate, plus required reviewers on the current
    /// head and a head that has stayed put with complete checks for
    /// `requiredStablePolls` polls. Never bypassed.
    public static func mergeGatePasses(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> Bool {
        guard ReviewReadinessModel.canMergeReviewRequest(snapshot: observation.snapshot),
              let head = observation.snapshot.reviewRequest?.headSHA,
              record.lastSeenHeadSHA == head,
              record.stableHeadPolls >= requiredStablePolls
        else { return false }
        let required = observation.rules.requiredReviewers
        guard !required.isEmpty else { return true }
        guard let reviewers = observation.headReviewers else { return false }
        return required.allSatisfy { reviewers.contains($0.lowercased()) }
    }

    /// Applied by the service after executing `.merge`. A nil outcome (head
    /// moved, gate no longer passes, provider error) returns the record to
    /// `watching` and makes it re-prove head stability.
    public static func applyMergeOutcome(
        _ outcome: ReviewMergeOutcome?,
        to record: ShepherdRecord,
        now: Date
    ) -> ShepherdRecord {
        var next = record
        switch outcome {
        case .merged:
            next.phase = .merged
            next.finishedAt = now
        case .queued:
            next.phase = .queued
        case nil:
            next.phase = .watching
            next.stableHeadPolls = 0
        }
        next.updatedAt = now
        return next
    }

    // MARK: - Rules

    private static func evaluate(
        _ record: inout ShepherdRecord,
        request: ReviewRequest,
        observation: ShepherdObservation
    ) -> ShepherdAction {
        let now = observation.now

        // Rule 1: terminal.
        switch request.state {
        case .merged:
            record.phase = .merged
            record.finishedAt = now
            return .finish(.merged)
        case .closed:
            record.phase = .closed
            record.finishedAt = now
            return .finish(.closed)
        case .open:
            break
        }

        updateHeadStability(&record, request: request)
        let problems = Self.problems(in: request)
        let conclusive = isConclusive(request, for: record.lastDispatchedFingerprint)
        // Failures hide behind incomplete checks, so clearing always needs
        // complete checks, whatever was dispatched.
        let cleared = conclusive && problems.isEmpty && !hasIncompleteChecks(request)

        // A merge attempt interrupted by a quit, or a merge queue the
        // provider no longer reports, falls back to watching.
        switch record.phase {
        case .merging:
            record.phase = .watching
        case .queued:
            if request.isInMergeQueue { return .wait }
            record.phase = .watching
        default:
            break
        }

        // Rule 2: escalated or paused.
        switch record.phase {
        case .paused:
            record.phase = .watching
        case .escalated(let reason):
            let ownerStillGone = reason == .ownerGone && record.autoFix
                && (observation.session == .archived || observation.session == .missing)
            guard cleared, !ownerStillGone else { return .wait }
            record.phase = .watching
        default:
            break
        }

        // Rule 3: auto-fix off skips straight to the merge rules.
        if record.autoFix {
            if let action = fixRules(&record, request: request, problems: problems, conclusive: conclusive,
                                     cleared: cleared, observation: observation) {
                return action
            }
        } else {
            switch record.phase {
            case .fixing, .awaitingPush: record.phase = .watching
            default: break
            }
        }

        return mergeRules(&record, request: request, observation: observation)
    }

    /// Rules 4 to 7. Nil means "continue to rule 8".
    private static func fixRules(
        _ record: inout ShepherdRecord,
        request: ReviewRequest,
        problems: ShepherdFixRequest,
        conclusive: Bool,
        cleared: Bool,
        observation: ShepherdObservation
    ) -> ShepherdAction? {
        // Rules 4 and 5: owner.
        switch observation.session {
        case .archived, .missing:
            record.phase = .escalated(.ownerGone)
            return .escalate(.ownerGone)
        case .busy:
            return .wait
        case .idle:
            break
        }

        // Rule 6: fix turn settled. Covers a normal turn end and a turn lost
        // to an app restart.
        if case .fixing = record.phase {
            record.phase = .awaitingPush(turnEndedAt: observation.now, pollsWithoutProgress: 0)
        }
        if case .awaitingPush(let turnEndedAt, let polls) = record.phase {
            if madeProgress(record, request: request, problems: problems, cleared: cleared) {
                record.phase = .watching
            } else if observation.now.timeIntervalSince(turnEndedAt) >= awaitingPushTimeout {
                record.phase = .escalated(.noProgress)
                return .escalate(.noProgress)
            } else if !conclusive {
                // Incomplete data about what was dispatched can hide the
                // problems; neither progress nor a miss.
                return .wait
            } else {
                let count = polls + 1
                if count >= noProgressPollLimit {
                    record.phase = .escalated(.noProgress)
                    return .escalate(.noProgress)
                }
                record.phase = .awaitingPush(turnEndedAt: turnEndedAt, pollsWithoutProgress: count)
                return .wait
            }
        }

        // Rule 7: problems.
        if problems.isEmpty {
            // Only a conclusive clean observation proves the dispatched
            // problems are gone; then the same problem returning is new work.
            if cleared {
                record.fixAttempts = 0
                record.lastDispatchedFingerprint = nil
                record.lastDispatchedAt = nil
            }
            return nil
        }
        let fingerprint = problems.fingerprint(headSHA: request.headSHA ?? "")
        if fingerprint == record.lastDispatchedFingerprint { return .wait }
        if record.fixAttempts >= maxFixAttempts {
            record.phase = .escalated(.attemptsExhausted)
            return .escalate(.attemptsExhausted)
        }
        record.phase = .fixing(dispatchedAt: observation.now)
        record.fixAttempts += 1
        record.lastDispatchedFingerprint = fingerprint
        record.lastDispatchedAt = observation.now
        return .dispatchFix(problems)
    }

    /// Rules 8 to 10.
    private static func mergeRules(
        _ record: inout ShepherdRecord,
        request: ReviewRequest,
        observation: ShepherdObservation
    ) -> ShepherdAction {
        guard mergeGatePasses(record, observation) else { return .wait }
        if record.autoMerge {
            record.phase = .merging
            return .merge
        }
        guard record.notifiedReadyHeadSHA != request.headSHA else { return .wait }
        record.notifiedReadyHeadSHA = request.headSHA
        return .notifyReady
    }

    // MARK: - Helpers

    /// Pending or unclassified: the check may still turn out to fail.
    private static func hasIncompleteChecks(_ request: ReviewRequest) -> Bool {
        request.checks.contains { $0.bucket == .pending || $0.bucket == .unknown }
    }

    /// Whether the observation is complete for every dimension that was
    /// dispatched: checks, conflict and threads. With nothing dispatched,
    /// all three must be complete.
    private static func isConclusive(_ request: ReviewRequest, for dispatched: ShepherdFingerprint?) -> Bool {
        let checksComplete = !hasIncompleteChecks(request)
        let mergeabilityKnown = request.mergeState != .unknown
        guard let dispatched else {
            return checksComplete && mergeabilityKnown && request.areThreadsComplete
        }
        return (dispatched.failingCheckIDs.isEmpty || checksComplete)
            && (!dispatched.hasConflict || mergeabilityKnown)
            && (dispatched.threadIDs.isEmpty || request.areThreadsComplete)
    }

    /// Same head with complete checks counts up; an incomplete check or a new
    /// head starts over. Capped so a stable record stays equal across polls.
    private static func updateHeadStability(_ record: inout ShepherdRecord, request: ReviewRequest) {
        let checksComplete = !hasIncompleteChecks(request)
        guard let head = request.headSHA else {
            record.lastSeenHeadSHA = nil
            record.stableHeadPolls = 0
            return
        }
        if head == record.lastSeenHeadSHA {
            record.stableHeadPolls = checksComplete
                ? min(record.stableHeadPolls + 1, requiredStablePolls)
                : 0
        } else {
            record.lastSeenHeadSHA = head
            record.stableHeadPolls = checksComplete ? 1 : 0
        }
    }

    /// Progress after a fix turn: a new provider head, a changed set of
    /// trusted thread revisions (only additions when the thread list is
    /// partial), the agent replying on a dispatched thread since the
    /// dispatch, or problems conclusively cleared.
    private static func madeProgress(
        _ record: ShepherdRecord,
        request: ReviewRequest,
        problems: ShepherdFixRequest,
        cleared: Bool
    ) -> Bool {
        guard let dispatched = record.lastDispatchedFingerprint else { return true }
        if cleared { return true }
        if (request.headSHA ?? "") != dispatched.headSHA { return true }
        let current = Set(problems.threadRevisions)
        let previous = Set(dispatched.threadIDs)
        if request.areThreadsComplete ? current != previous : !current.isSubset(of: previous) { return true }
        guard let dispatchedAt = record.lastDispatchedAt else { return false }
        let since = dispatchedAt.addingTimeInterval(-replyClockSkew)
        return problems.threads.contains { thread in
            previous.contains(ShepherdFixRequest.revision(of: thread))
                && thread.comments.contains { comment in
                    guard comment.viewerDidAuthor, let createdAt = comment.createdAt else { return false }
                    return createdAt >= since
                }
        }
    }
}
