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
    /// A head that reports no checks at all may just not have its CI
    /// registered yet, so the empty list counts as green only this long
    /// after the policy first saw the head.
    public static let noChecksGracePeriod: TimeInterval = 15 * 60

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

    /// The dispatchable problems. Threads whose current revision is in
    /// `handled` (the agent already answered that feedback) are left out.
    public static func problems(in request: ReviewRequest, handled: [String]) -> ShepherdFixRequest {
        let handled = Set(handled)
        return ShepherdFixRequest(
            hasConflict: request.mergeState == .dirty,
            // Partial CI results never trigger a fix.
            failingChecks: hasIncompleteChecks(request)
                ? [] : request.checks.filter { $0.bucket == .fail || $0.bucket == .cancel },
            threads: trustedThreads(in: request).filter { !handled.contains(ShepherdFixRequest.revision(of: $0)) }
        )
    }

    /// The existing readiness gate, plus required reviewers on the current
    /// head, a head that has stayed put with complete checks for
    /// `requiredStablePolls` polls, and, when the head reports no checks,
    /// `noChecksGracePeriod` since it was first seen. Never bypassed.
    public static func mergeGatePasses(_ record: ShepherdRecord, _ observation: ShepherdObservation) -> Bool {
        guard ReviewReadinessModel.canMergeReviewRequest(snapshot: observation.snapshot),
              let request = observation.snapshot.reviewRequest,
              let head = request.headSHA,
              record.lastSeenHeadSHA == head,
              record.stableHeadPolls >= requiredStablePolls,
              !awaitingFirstChecks(record, request: request, now: observation.now)
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

        let headUnchanged = request.headSHA != nil && request.headSHA == record.lastSeenHeadSHA
        updateHeadStability(&record, request: request, now: now)
        pruneHandled(&record, request: request)
        let problems = Self.problems(in: request, handled: record.handledThreadRevisions ?? [])
        let conclusive = isConclusive(request, for: record.lastDispatchedFingerprint)
        let cleared = isCleared(request, problems: problems, conclusive: conclusive)

        // A merge attempt interrupted by a quit, or a merge queue the
        // provider no longer reports, falls back to watching. A provider
        // without merge-queue reporting (a GitLab merge train) can accept a
        // merge that lands later: that holds while the head stands, no check
        // failed or was cancelled (a stopped train) and nothing else needs the
        // session (a conflict after the target moved, a new trusted thread),
        // so the record is not merged a second time.
        switch record.phase {
        case .merging:
            record.phase = .watching
        case .queued:
            if request.isInMergeQueue { return .wait }
            let trainStopped = request.worstCheckBucket == .fail || request.worstCheckBucket == .cancel
            if !request.isMergeQueueEnabled, headUnchanged, !trainStopped, problems.isEmpty { return .wait }
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
        var problems = problems
        if case .awaitingPush(let turnEndedAt, let polls) = record.phase {
            let replied = repliedRevisions(record, problems: problems)
            if !replied.isEmpty || madeProgress(record, request: request, problems: problems, cleared: cleared) {
                // The turn is over. The agent answered the replied threads;
                // rule 7 drops the fingerprint, so everything else that
                // survives goes out again as the next attempt.
                record.phase = .watching
                if !replied.isEmpty {
                    record.handledThreadRevisions = Set(record.handledThreadRevisions ?? []).union(replied).sorted()
                    problems = Self.problems(in: request, handled: record.handledThreadRevisions ?? [])
                }
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

        // Rule 7: problems. No fix turn is outstanding here, so a fingerprint
        // left over from an earlier turn (a pause, auto-fix toggled, an older
        // record) never holds back the problems in front of us.
        record.lastDispatchedFingerprint = nil
        record.viewerCommentIDsAtDispatch = nil
        if problems.isEmpty {
            if isCleared(request, problems: problems, conclusive: isConclusive(request, for: nil)),
               !awaitingFirstChecks(record, request: request, now: observation.now) {
                record.fixAttempts = 0
            }
            return nil
        }
        if record.fixAttempts >= maxFixAttempts {
            record.phase = .escalated(.attemptsExhausted)
            return .escalate(.attemptsExhausted)
        }
        record.phase = .fixing(dispatchedAt: observation.now)
        record.fixAttempts += 1
        record.lastDispatchedFingerprint = problems.fingerprint(headSHA: request.headSHA ?? "")
        record.viewerCommentIDsAtDispatch = problems.threads
            .flatMap(\.comments)
            .filter(\.viewerDidAuthor)
            .map(\.id)
            .sorted()
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

    /// No checks reported on a head first seen less than
    /// `noChecksGracePeriod` ago (or never): its CI may not have registered
    /// yet, so the empty list proves nothing.
    private static func awaitingFirstChecks(_ record: ShepherdRecord, request: ReviewRequest, now: Date) -> Bool {
        guard request.checks.isEmpty else { return false }
        guard let firstSeen = record.headFirstSeenAt else { return true }
        return now.timeIntervalSince(firstSeen) < noChecksGracePeriod
    }

    /// Actionable threads whose head comment is from a trusted reviewer.
    private static func trustedThreads(in request: ReviewRequest) -> [ReviewThread] {
        request.threads.filter { $0.isActionable && $0.headAuthorTrust == .trusted }
    }

    /// Problems conclusively gone. Failures hide behind incomplete checks,
    /// so this always needs complete checks, whatever was dispatched.
    private static func isCleared(_ request: ReviewRequest, problems: ShepherdFixRequest, conclusive: Bool) -> Bool {
        conclusive && problems.isEmpty && !hasIncompleteChecks(request)
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

    /// Forgets handled revisions that no longer exist (thread resolved,
    /// outdated or deleted), judged only on a complete thread list.
    private static func pruneHandled(_ record: inout ShepherdRecord, request: ReviewRequest) {
        guard request.areThreadsComplete, let handled = record.handledThreadRevisions else { return }
        let present = Set(trustedThreads(in: request).map(ShepherdFixRequest.revision(of:)))
        let kept = handled.filter(present.contains)
        if kept != handled { record.handledThreadRevisions = kept.isEmpty ? nil : kept }
    }

    /// Same head with complete checks counts up; an incomplete check or a new
    /// head starts over. Capped so a stable record stays equal across polls.
    /// A new head also restarts the no-checks clock; a record saved before
    /// the clock existed starts it on this poll.
    private static func updateHeadStability(_ record: inout ShepherdRecord, request: ReviewRequest, now: Date) {
        let checksComplete = !hasIncompleteChecks(request)
        guard let head = request.headSHA else {
            record.lastSeenHeadSHA = nil
            record.stableHeadPolls = 0
            record.headFirstSeenAt = nil
            return
        }
        if head == record.lastSeenHeadSHA {
            record.stableHeadPolls = checksComplete
                ? min(record.stableHeadPolls + 1, requiredStablePolls)
                : 0
            if record.headFirstSeenAt == nil { record.headFirstSeenAt = now }
        } else {
            record.lastSeenHeadSHA = head
            record.headFirstSeenAt = now
            record.stableHeadPolls = checksComplete ? 1 : 0
        }
    }

    /// Progress after a fix turn, judged against the dispatched fingerprint:
    /// a new provider head, a dispatched check or conflict conclusively gone,
    /// a changed set of trusted thread revisions (only additions when the
    /// thread list is partial), or problems conclusively cleared. Agent
    /// replies are `repliedRevisions`.
    private static func madeProgress(
        _ record: ShepherdRecord,
        request: ReviewRequest,
        problems: ShepherdFixRequest,
        cleared: Bool
    ) -> Bool {
        guard let dispatched = record.lastDispatchedFingerprint else { return true }
        if cleared { return true }
        if (request.headSHA ?? "") != dispatched.headSHA { return true }
        if !hasIncompleteChecks(request) {
            let failing = Set(problems.failingChecks.map(\.id))
            if dispatched.failingCheckIDs.contains(where: { !failing.contains($0) }) { return true }
        }
        if dispatched.hasConflict, request.mergeState != .unknown, !problems.hasConflict { return true }
        let current = Set(problems.threadRevisions)
        let previous = Set(dispatched.threadIDs)
        return request.areThreadsComplete ? current != previous : !current.isSubset(of: previous)
    }

    /// Revisions of dispatched threads that gained a viewer comment that did
    /// not exist at dispatch: the agent answered them. Records saved before
    /// reply tracking never count a reply.
    private static func repliedRevisions(_ record: ShepherdRecord, problems: ShepherdFixRequest) -> [String] {
        guard let dispatched = record.lastDispatchedFingerprint,
              let known = record.viewerCommentIDsAtDispatch.map(Set.init)
        else { return [] }
        let previous = Set(dispatched.threadIDs)
        return problems.threads.compactMap { thread in
            let revision = ShepherdFixRequest.revision(of: thread)
            guard previous.contains(revision),
                  thread.comments.contains(where: { $0.viewerDidAuthor && !known.contains($0.id) })
            else { return nil }
            return revision
        }
    }
}
