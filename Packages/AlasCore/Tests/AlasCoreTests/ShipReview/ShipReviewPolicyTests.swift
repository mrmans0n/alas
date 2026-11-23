import Foundation
import Testing
import AlasModel
@testable import AlasIntegrations

private let t0 = Date(timeIntervalSince1970: 1_000)
private let t1 = Date(timeIntervalSince1970: 2_000)
private let pullRequest = ShipReviewTarget.pullRequest(PendingPRPush(title: "Add review", body: "Body", draft: false, base: nil))

/// A lever-on record with a pending PR push. `rounds` earlier rounds with
/// findings count toward this push; `.reviewing` adds the running round,
/// `.awaitingFix` moves the latest findings round onto its head.
private func record(_ phase: ShipReviewPhase = .idle, rounds: Int = 0, max: Int = 3, passed: [String] = []) -> ShipReviewRecord {
    var r = ShipReviewRecord(id: ShipReviewID(worktreeID: "w1", sessionID: "s1"), enabled: true, reviewer: nil, maxRounds: max, now: t0)
    r.pending = pullRequest
    r.phase = phase
    r.roundsThisPush = rounds
    r.passedSHAs = passed
    r.rounds = (0..<rounds).map {
        ShipReviewRound(number: $0 + 1, headSHA: "h0", verdict: .requestChanges, openFindingIDs: ["f\($0)"], reviewerLabel: "Codex", reviewedAt: t0)
    }
    switch phase {
    case let .reviewing(headSHA, _):
        r.rounds.append(ShipReviewRound(number: rounds + 1, headSHA: headSHA, reviewerLabel: "Codex"))
    case let .awaitingFix(headSHA) where !r.rounds.isEmpty:
        r.rounds[r.rounds.count - 1].headSHA = headSHA
    default:
        break
    }
    return r
}

private func result(_ verdict: ReviewVerdict, findings: Int) -> CodeReviewResult {
    CodeReviewResult(
        verdict: verdict,
        summary: "Summary",
        findings: (0..<findings).map { CodeReviewFinding(path: "Sources/A.swift", anchor: .line(start: $0 + 1, end: $0 + 1), body: "Fix \($0)") },
        resolvedIDs: []
    )
}

struct ShipReviewLineCase: Sendable, CustomTestStringConvertible {
    let name: String
    let record: ShipReviewRecord
    let expected: ShipReviewLine?

    var testDescription: String { name }
}

let shipReviewLineCases: [ShipReviewLineCase] = {
    let sha = "a1b2c3d4e5f6"
    var clean = record(passed: [sha])
    clean.rounds = [ShipReviewRound(number: 1, headSHA: sha, verdict: .approve, reviewerLabel: "Codex", reviewedAt: t0)]
    var findings = record(.awaitingFix(headSHA: sha), rounds: 1)
    findings.rounds[0].openFindingIDs = ["f1", "f2"]
    var unreviewed = record()
    unreviewed.unreviewedRemoteHead = "9f8e7d6c5b4a"
    var off = record(.reviewing(headSHA: sha, startedAt: t0))
    off.enabled = false
    let stopped = { (stop: ShipReviewStop) in record(.stopped(stop), rounds: 3) }
    return [
        ShipReviewLineCase(
            name: "reviewing",
            record: record(.reviewing(headSHA: sha, startedAt: t0)),
            expected: ShipReviewLine(tone: .running, text: "Codex is reviewing a1b2c3d…", actions: [.openSession])
        ),
        ShipReviewLineCase(
            name: "clean",
            record: clean,
            expected: ShipReviewLine(tone: .clean, text: "Codex reviewed a1b2c3d before the push", actions: [.openReview])
        ),
        ShipReviewLineCase(
            name: "findings sent",
            record: findings,
            expected: ShipReviewLine(tone: .findings, text: "Codex review: 2 findings on a1b2c3d, sent to this session", actions: [.openReview])
        ),
        ShipReviewLineCase(
            name: "unreviewed remote head",
            record: unreviewed,
            expected: ShipReviewLine(tone: .stopped, text: "9f8e7d6 reached GitHub without a review", actions: [.allow])
        ),
        ShipReviewLineCase(
            name: "rounds spent",
            record: stopped(.roundsExhausted(openFindings: 1)),
            expected: ShipReviewLine(tone: .stopped, text: "3 review rounds spent, 1 finding still open. Nothing was pushed.", actions: [.openReview, .shipAnyway])
        ),
        ShipReviewLineCase(
            name: "auto-fix off",
            record: stopped(.findingsWithAutoFixOff(count: 2)),
            expected: ShipReviewLine(tone: .stopped, text: "2 findings. Auto-fix is off, so nothing was pushed.", actions: [.openReview, .sendToSession])
        ),
        ShipReviewLineCase(
            name: "reviewer failed",
            record: stopped(.reviewerFailed("Codex is not signed in")),
            expected: ShipReviewLine(tone: .stopped, text: "Review didn't finish: Codex is not signed in. Nothing was pushed.", actions: [.retry, .shipAnyway])
        ),
        ShipReviewLineCase(
            name: "unreadable file",
            record: stopped(.instructionsUnreadable(".alas/code-review.md: denied")),
            expected: ShipReviewLine(tone: .stopped, text: "Couldn't read .alas/code-review.md: denied. Nothing was pushed.", actions: [.retry, .shipAnyway])
        ),
        ShipReviewLineCase(
            name: "no progress",
            record: stopped(.noProgress(openFindings: 2)),
            expected: ShipReviewLine(
                tone: .stopped,
                text: "The session ended its turn without a fix, 2 findings still open. Nothing was pushed.",
                actions: [.openReview, .shipAnyway]
            )
        ),
        ShipReviewLineCase(
            name: "push failed",
            record: stopped(.pushFailed("rejected")),
            expected: ShipReviewLine(tone: .stopped, text: "Push failed: rejected", actions: [.retry])
        ),
        ShipReviewLineCase(name: "lever off", record: off, expected: nil),
    ]
}()

@Suite struct ShipReviewPolicyTests {
    @Test("a push request reviews unless the lever is off or the SHA passed", arguments: [
        (true, [String](), ShipReviewAction.startRound(headSHA: "h1")),
        (false, [], .push(headSHA: "h1")),
        (true, ["h1"], .push(headSHA: "h1")),
    ])
    func requestPush(enabled: Bool, passed: [String], expected: ShipReviewAction) {
        var r = record(passed: passed)
        r.pending = nil
        r.enabled = enabled

        let (next, action) = ShipReviewPolicy.requestPush(r, target: pullRequest, headSHA: "h1", now: t1)

        #expect(action == expected)
        if case .startRound = expected {
            #expect(next.phase == .reviewing(headSHA: "h1", startedAt: t1))
            #expect(next.pending == pullRequest)
            #expect(next.currentRound?.number == 1)
            #expect(next.currentRound?.headSHA == "h1")
        } else {
            #expect(next.phase == .idle)
            #expect(next.pending == nil)
        }
    }

    @Test("review outcomes", arguments: [
        // verdict, findings, autoFix, roundsBefore, expected action
        (ReviewVerdict.approve, 0, true, 0, ShipReviewAction.push(headSHA: "h1")),
        (.approve, 2, true, 0, .push(headSHA: "h1")), // approve stays clean; findings are filed, not sent
        (.comment, 0, true, 0, .push(headSHA: "h1")),
        (.comment, 1, true, 0, .sendFindings(round: 1)),
        (.requestChanges, 2, false, 0, .stop(.findingsWithAutoFixOff(count: 2))),
        (.requestChanges, 1, true, 2, .stop(.roundsExhausted(openFindings: 1))),
    ])
    func reviewOutcomes(verdict: ReviewVerdict, findings: Int, autoFix: Bool, roundsBefore: Int, expected: ShipReviewAction) {
        let r = record(.reviewing(headSHA: "h1", startedAt: t0), rounds: roundsBefore)

        let (next, action) = ShipReviewPolicy.reviewFinished(
            r,
            reviewedSHA: "h1",
            currentHeadSHA: "h1",
            outcome: .success(result(verdict, findings: findings)),
            autoFix: autoFix,
            now: t1
        )

        #expect(action == expected)
        #expect(next.currentRound?.verdict == verdict)
        #expect(next.currentRound?.reviewedAt == t1)
        switch expected {
        case .push:
            #expect(next.phase == .pushing(headSHA: "h1"))
            #expect(next.passedSHAs == ["h1"])
            #expect(next.roundsThisPush == roundsBefore)
        case .sendFindings:
            #expect(next.phase == .awaitingFix(headSHA: "h1"))
            #expect(next.passedSHAs.isEmpty)
            #expect(next.roundsThisPush == roundsBefore + 1)
        case let .stop(stop):
            #expect(next.phase == .stopped(stop))
            #expect(next.passedSHAs.isEmpty)
            #expect(next.roundsThisPush == roundsBefore + 1)
        case .none, .startRound:
            Issue.record("unexpected case \(expected)")
        }
    }

    @Test func headMovedDuringReviewRestartsWithoutCounting() {
        let r = record(.reviewing(headSHA: "h1", startedAt: t0), rounds: 1)

        let (next, action) = ShipReviewPolicy.reviewFinished(
            r,
            reviewedSHA: "h1",
            currentHeadSHA: "h2",
            outcome: .success(result(.approve, findings: 0)),
            autoFix: true,
            now: t1
        )

        #expect(action == .startRound(headSHA: "h2"))
        #expect(next.roundsThisPush == 1)
        #expect(next.phase == .reviewing(headSHA: "h2", startedAt: t1))
        #expect(next.passedSHAs.isEmpty)
        #expect(next.rounds.count == 2)
        #expect(next.currentRound?.number == 2)
        #expect(next.currentRound?.headSHA == "h2")
        #expect(next.currentRound?.verdict == nil)
    }

    @Test func failedReviewStopsWithoutCounting() {
        let cases: [(ShipReviewFailure, ShipReviewStop)] = [
            (.reviewer("Codex is not signed in"), .reviewerFailed("Codex is not signed in")),
            (.noResult, .reviewerFailed("the reviewer returned no result")),
        ]
        for (failure, stop) in cases {
            let r = record(.reviewing(headSHA: "h1", startedAt: t0), rounds: 1)

            let (next, action) = ShipReviewPolicy.reviewFinished(
                r,
                reviewedSHA: "h1",
                currentHeadSHA: "h1",
                outcome: .failure(failure),
                autoFix: true,
                now: t1
            )

            #expect(action == .stop(stop))
            #expect(next.phase == .stopped(stop))
            #expect(next.roundsThisPush == 1)
            #expect(next.currentRound?.reviewedAt == nil)
            #expect(next.passedSHAs.isEmpty)
        }
    }

    @Test("owner turn ends", arguments: [
        ("h2", 1, ShipReviewAction.startRound(headSHA: "h2")), // new commit → next round
        ("h1", 0, .push(headSHA: "h1")), // no commit, owner resolved everything
        ("h1", 1, .stop(.noProgress(openFindings: 1))),
    ])
    func ownerTurnWithoutCommitPushesOnlyIfFindingsWereResolved(head: String, open: Int, expected: ShipReviewAction) {
        let r = record(.awaitingFix(headSHA: "h1"), rounds: 1)

        let (next, action) = ShipReviewPolicy.ownerTurnEnded(r, headSHA: head, openFindings: open, now: t1)

        #expect(action == expected)
        #expect(next.roundsThisPush == 1)
        switch expected {
        case .startRound:
            #expect(next.phase == .reviewing(headSHA: "h2", startedAt: t1))
            #expect(next.currentRound?.number == 2)
            #expect(next.passedSHAs.isEmpty)
        case .push:
            #expect(next.phase == .pushing(headSHA: "h1"))
            #expect(next.passedSHAs == ["h1"])
        case let .stop(stop):
            #expect(next.phase == .stopped(stop))
            #expect(next.passedSHAs.isEmpty)
        case .none, .sendFindings:
            Issue.record("unexpected case \(expected)")
        }
    }

    /// Findings about paths outside the diff are folded into the summary and
    /// filed nowhere: no comment can resolve them, so only a commit answers them.
    @Test func requestChangesWithNothingFiledNeedsACommit() {
        var r = record(.awaitingFix(headSHA: "h1"), rounds: 1)
        r.rounds[r.rounds.count - 1].openFindingIDs = []

        let (next, action) = ShipReviewPolicy.ownerTurnEnded(r, headSHA: "h1", openFindings: 0, now: t1)

        #expect(action == .stop(.noProgress(openFindings: 0)))
        #expect(next.phase == .stopped(.noProgress(openFindings: 0)))
        #expect(next.passedSHAs.isEmpty)
    }

    @Test func relaunchRestartsRunningRound() {
        var r = record(.reviewing(headSHA: "h1", startedAt: t0), rounds: 1)
        r.reviewerSessionID = "reviewer-1"

        let (next, action) = ShipReviewPolicy.relaunched(r, now: t1)

        #expect(action == .startRound(headSHA: "h1"))
        #expect(next.roundsThisPush == 1)
        #expect(next.phase == .reviewing(headSHA: "h1", startedAt: t1))
        #expect(next.reviewerSessionID == nil)
        #expect(next.rounds.count == 2)
        #expect(next.currentRound?.number == 2)
        #expect(next.currentRound?.headSHA == "h1")
    }

    @Test func pushResetsTheRoundCountAndRecordsThePass() {
        let r = record(.pushing(headSHA: "h1"), rounds: 2)

        let pushed = ShipReviewPolicy.pushFinished(r, headSHA: "h1", error: nil, now: t1)
        #expect(pushed.phase == .idle)
        #expect(pushed.roundsThisPush == 0)
        #expect(pushed.pending == nil)
        #expect(pushed.passedSHAs.contains("h1"))

        let failed = ShipReviewPolicy.pushFinished(r, headSHA: "h1", error: "rejected", now: t1)
        #expect(failed.phase == .stopped(.pushFailed("rejected")))
        #expect(failed.roundsThisPush == 2)
        #expect(failed.pending == pullRequest)
    }

    @Test("review line by state", arguments: shipReviewLineCases)
    func reviewLine(_ c: ShipReviewLineCase) {
        #expect(ShipReviewPresentation.line(c.record, reviewerName: "Codex", providerName: "GitHub") == c.expected)
    }
    @Test("verdict banner actions by round", arguments: [
        // (phase, round's session is the latest, pending, expected)
        (ShipReviewPhase.stopped(.reviewerFailed("x")), true, true, [ShipReviewLineAction.retry, .shipAnyway]),
        (.stopped(.pushFailed("x")), true, false, [.retry]),
        (.stopped(.reviewerFailed("x")), false, true, []),
        (.awaitingFix(headSHA: "h2"), true, true, [.shipAnyway]),
        (.awaitingFix(headSHA: "h3"), true, true, []),
        (.awaitingFix(headSHA: "h2"), false, true, []),
        (.reviewing(headSHA: "h2", startedAt: t0), true, true, [.shipAnyway]),
        (.pushing(headSHA: "h2"), true, true, []),
        (.idle, true, true, []),
        (.idle, true, false, []),
    ] as [(ShipReviewPhase, Bool, Bool, [ShipReviewLineAction])])
    func bannerActions(_ phase: ShipReviewPhase, latest: Bool, pending: Bool, expected: [ShipReviewLineAction]) {
        var r = record()
        r.pending = pending ? pullRequest : nil
        r.phase = phase
        // Round numbers restart per push: both rounds are round 1.
        r.rounds = [
            ShipReviewRound(number: 1, headSHA: "h1", reviewSessionID: ReviewSessionID(rawValue: "old"), verdict: .requestChanges, openFindingIDs: ["f"], reviewerLabel: "Codex", reviewedAt: t0),
            ShipReviewRound(number: 1, headSHA: "h2", reviewSessionID: ReviewSessionID(rawValue: "new"), verdict: .requestChanges, openFindingIDs: ["f"], reviewerLabel: "Codex", reviewedAt: t1),
        ]
        let session = ReviewSessionID(rawValue: latest ? "new" : "old")
        #expect(ShipReviewPresentation.bannerActions(record: r, roundSessionID: session) == expected)
    }
}
