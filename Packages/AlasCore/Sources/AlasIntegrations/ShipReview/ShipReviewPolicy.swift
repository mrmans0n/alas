import Foundation
import AlasModel

/// Pure decisions for review before push. Each call returns the updated
/// record and what the coordinator should do; it never pushes a head that
/// isn't the one reviewed, allowed, or resolved by the owner.
public enum ShipReviewPolicy {
    /// A push request. Lever off or SHA already passed → `.push`; else start or keep a round.
    public static func requestPush(
        _ r: ShipReviewRecord,
        target: ShipReviewTarget,
        headSHA: String,
        now: Date
    ) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        r.updatedAt = now
        guard r.enabled, !r.passedSHAs.contains(headSHA) else {
            // The caller pushes now. The phase is left alone: a push the
            // coordinator started settles in `pushFinished`.
            return (r, .push(headSHA: headSHA))
        }
        r.pending = target
        switch r.phase {
        case let .reviewing(reviewing, _) where reviewing == headSHA:
            return (r, .none)
        case let .awaitingFix(findingsHead) where findingsHead == headSHA:
            // No new commit yet; the owner's turn end decides.
            return (r, .none)
        default:
            return beginRound(r, headSHA: headSHA, now: now)
        }
    }

    /// The reviewer's outcome for `reviewedSHA`, with the worktree's HEAD read after the turn.
    public static func reviewFinished(
        _ r: ShipReviewRecord,
        reviewedSHA: String,
        currentHeadSHA: String,
        outcome: Result<CodeReviewResult, ShipReviewFailure>,
        autoFix: Bool,
        now: Date
    ) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        guard case let .reviewing(reviewing, _) = r.phase, reviewing == reviewedSHA else { return (r, .none) }
        r.updatedAt = now
        // The review no longer describes HEAD: discard it, uncounted.
        guard currentHeadSHA == reviewedSHA else {
            return startRound(r, headSHA: currentHeadSHA, now: now)
        }
        let result: CodeReviewResult
        switch outcome {
        case let .failure(failure):
            switch failure {
            case let .reviewer(reason): return stop(r, .reviewerFailed(reason))
            case .noResult: return stop(r, .reviewerFailed("the reviewer returned no result"))
            case let .instructions(reason): return stop(r, .instructionsUnreadable(reason))
            }
        case let .success(value):
            result = value
        }

        if var round = r.rounds.last, round.reviewedAt == nil, round.headSHA == reviewedSHA {
            round.verdict = result.verdict
            round.summary = result.summary
            round.reviewedAt = now
            r.rounds[r.rounds.count - 1] = round
        }

        if result.isClean {
            return passAndPush(r, headSHA: reviewedSHA)
        }

        let count = result.findings.count
        r.roundsThisPush += 1
        if !autoFix {
            return stop(r, .findingsWithAutoFixOff(count: count))
        }
        if r.roundsThisPush >= r.maxRounds {
            return stop(r, .roundsExhausted(openFindings: count))
        }
        r.phase = .awaitingFix(headSHA: reviewedSHA)
        return (r, .sendFindings(round: r.currentRound?.number ?? r.roundsThisPush))
    }

    /// The owner's turn ended. `openFindings` counts the round's findings still active in the pane.
    public static func ownerTurnEnded(
        _ r: ShipReviewRecord,
        headSHA: String,
        openFindings: Int,
        now: Date
    ) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        guard case let .awaitingFix(findingsHead) = r.phase else { return (r, .none) }
        r.updatedAt = now
        if headSHA != findingsHead {
            return beginRound(r, headSHA: headSHA, now: now)
        }
        if openFindings == 0 {
            // The owner resolved every finding without a commit: the reviewed SHA goes out.
            return passAndPush(r, headSHA: findingsHead)
        }
        return stop(r, .noProgress(openFindings: openFindings))
    }

    /// Settles the push the coordinator started. A newer request that began
    /// a round meanwhile keeps its phase; a successful push still passes the SHA.
    public static func pushFinished(_ r: ShipReviewRecord, headSHA: String, error: String?, now: Date) -> ShipReviewRecord {
        var r = r
        r.updatedAt = now
        let settlesPhase = r.phase == .pushing(headSHA: headSHA)
        if let error {
            if settlesPhase { r.phase = .stopped(.pushFailed(error)) }
            return r
        }
        appendPassed(&r, headSHA)
        if r.unreviewedRemoteHead == headSHA { r.unreviewedRemoteHead = nil }
        if settlesPhase {
            r.phase = .idle
            r.pending = nil
            r.roundsThisPush = 0
        }
        return r
    }

    /// "Ship anyway", "Ship without review", "Allow".
    public static func allow(_ r: ShipReviewRecord, headSHA: String, now: Date) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        r.updatedAt = now
        appendPassed(&r, headSHA)
        if r.unreviewedRemoteHead == headSHA { r.unreviewedRemoteHead = nil }
        if r.pending != nil {
            r.phase = .pushing(headSHA: headSHA)
            return (r, .push(headSHA: headSHA))
        }
        r.phase = .idle
        return (r, .none)
    }

    /// A round that was running restarts on the same SHA with a fresh reviewer
    /// session and doesn't count; an interrupted push is retried.
    public static func relaunched(_ r: ShipReviewRecord, now: Date) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        switch r.phase {
        case let .reviewing(headSHA, _):
            r.updatedAt = now
            r.reviewerSessionID = nil
            return startRound(r, headSHA: headSHA, now: now)
        case let .pushing(headSHA):
            r.updatedAt = now
            guard r.pending != nil else {
                r.phase = .idle
                return (r, .none)
            }
            return (r, .push(headSHA: headSHA))
        case .idle, .awaitingFix, .stopped:
            return (r, .none)
        }
    }

    /// Nil record or lever off → true; else the head is clean or allowed.
    public static func passed(_ r: ShipReviewRecord?, headSHA: String?) -> Bool {
        guard let r, r.enabled else { return true }
        guard let headSHA else { return false }
        return r.passedSHAs.contains(headSHA)
    }

    // MARK: - Helpers

    /// Starts a round unless this push already spent its rounds.
    private static func beginRound(_ r: ShipReviewRecord, headSHA: String, now: Date) -> (ShipReviewRecord, ShipReviewAction) {
        guard r.roundsThisPush < r.maxRounds else {
            return stop(r, .roundsExhausted(openFindings: r.currentRound?.openFindingIDs.count ?? 0))
        }
        return startRound(r, headSHA: headSHA, now: now)
    }

    /// Appends the round, replacing an unfinished one: a discarded, failed or
    /// interrupted round never counts and keeps its number.
    private static func startRound(_ r: ShipReviewRecord, headSHA: String, now: Date) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        if let last = r.rounds.last, last.reviewedAt == nil {
            r.rounds.removeLast()
        }
        r.rounds.append(ShipReviewRound(number: r.roundsThisPush + 1, headSHA: headSHA))
        if r.rounds.count > ShipReviewRecord.roundHistoryLimit {
            r.rounds.removeFirst(r.rounds.count - ShipReviewRecord.roundHistoryLimit)
        }
        r.phase = .reviewing(headSHA: headSHA, startedAt: now)
        return (r, .startRound(headSHA: headSHA))
    }

    private static func passAndPush(_ r: ShipReviewRecord, headSHA: String) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        appendPassed(&r, headSHA)
        guard r.pending != nil else {
            r.phase = .idle
            r.roundsThisPush = 0
            if r.unreviewedRemoteHead == headSHA { r.unreviewedRemoteHead = nil }
            return (r, .none)
        }
        r.phase = .pushing(headSHA: headSHA)
        return (r, .push(headSHA: headSHA))
    }

    private static func stop(_ r: ShipReviewRecord, _ stop: ShipReviewStop) -> (ShipReviewRecord, ShipReviewAction) {
        var r = r
        r.phase = .stopped(stop)
        return (r, .stop(stop))
    }

    private static func appendPassed(_ r: inout ShipReviewRecord, _ headSHA: String) {
        r.passedSHAs.removeAll { $0 == headSHA }
        r.passedSHAs.append(headSHA)
        if r.passedSHAs.count > ShipReviewRecord.passedSHALimit {
            r.passedSHAs.removeFirst(r.passedSHAs.count - ShipReviewRecord.passedSHALimit)
        }
    }
}
