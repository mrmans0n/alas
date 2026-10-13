import Foundation
import Testing
@testable import AlasCore

private typealias F = ShepherdFixtures

struct ShepherdPolicyCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let record: ShepherdRecord
    let observation: ShepherdObservation
    let action: ShepherdAction
    let phase: ShepherdPhase
}

struct ShepherdStabilityCase: Sendable, CustomTestStringConvertible {
    let lastSeen: String
    let polls: Int
    let bucket: ReviewCheckBucket
    let expected: Int
    var testDescription: String {
        "\(lastSeen == ShepherdFixtures.head ? "same" : "new") head, \(polls) polls, \(bucket)"
    }
}

private let stabilityCases: [ShepherdStabilityCase] = [
    .init(lastSeen: F.head, polls: 1, bucket: .pass, expected: 2),
    .init(lastSeen: F.head, polls: 2, bucket: .pass, expected: 2),
    .init(lastSeen: F.head, polls: 1, bucket: .pending, expected: 0),
    .init(lastSeen: "0ld", polls: 1, bucket: .pass, expected: 1),
    .init(lastSeen: "0ld", polls: 1, bucket: .pending, expected: 0),
]

private let failingOnly = ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing], threads: [])
private let threadOnly = ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [F.trustedThread])
/// Same head comment as `F.trustedThread`, so only the reply differs.
private let repliedThread = F.thread("PRRT_1", comments: [
    F.comment("PRRT_1-c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "me", body: "Backoff already lives in RetryPolicy.", trust: .untrusted, viewer: true),
])
private let followUpThread = F.thread("PRRT_1", comments: [
    F.comment("PRRT_1-c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "me", body: "Backoff already lives in RetryPolicy.", trust: .untrusted, viewer: true),
    F.comment("c3", author: "maintainer", body: "It doesn't cover uploads.", trust: .trusted),
])
private let driveByThread = F.thread("PRRT_1", comments: [
    F.comment("PRRT_1-c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "passerby", body: "+1", trust: .untrusted),
])
private let codexRules = ShepherdRules(source: .repoFile, instructions: "", requiredReviewers: ["chatgpt-codex-connector"])
private let mixedCaseRules = ShepherdRules(source: .projectSettings, instructions: "", requiredReviewers: ["ChatGPT-Codex-Connector"])
private let outdatedThread = ReviewThread(
    id: "PRRT_9", path: "Sources/App.swift", line: 12, startLine: nil, originalLine: nil,
    diffHunk: nil, isResolved: false, isOutdated: true, isFileLevel: false,
    comments: [F.comment("c9", author: "maintainer", body: "Old note.", trust: .trusted)],
    viewerCanResolve: true, viewerCanReply: true, url: nil
)
/// Same head already seen once with complete checks: this poll makes it stable.
private func stable(autoFix: Bool = true, autoMerge: Bool = false, phase: ShepherdPhase = .watching) -> ShepherdRecord {
    F.record(phase: phase, autoFix: autoFix, autoMerge: autoMerge, lastSeenHead: F.head, stablePolls: 1)
}

private let policyCases: [ShepherdPolicyCase] = [
    // Rule 1
    .init(testDescription: "merged request finishes",
          record: F.record(), observation: F.observation(F.snapshot(F.request(state: .merged))),
          action: .finish(.merged), phase: .merged),
    .init(testDescription: "closed request finishes",
          record: F.record(), observation: F.observation(F.snapshot(F.request(state: .closed))),
          action: .finish(.closed), phase: .closed),
    // Rule 2
    .init(testDescription: "escalated record waits while problems remain",
          record: F.record(phase: .escalated(.attemptsExhausted), fixAttempts: 3),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .wait, phase: .escalated(.attemptsExhausted)),
    .init(testDescription: "escalated record returns to watching when problems clear",
          record: F.record(phase: .escalated(.noProgress)),
          observation: F.observation(F.snapshot(F.request())),
          action: .wait, phase: .watching),
    .init(testDescription: "escalation does not clear while a check is pending",
          record: F.record(phase: .escalated(.noProgress), fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .wait, phase: .escalated(.noProgress)),
    .init(testDescription: "owner-gone escalation holds while the owner is gone",
          record: F.record(phase: .escalated(.ownerGone)),
          observation: F.observation(F.snapshot(F.request()), session: .archived),
          action: .wait, phase: .escalated(.ownerGone)),
    .init(testDescription: "paused record resumes on a successful fetch",
          record: stable(autoMerge: true, phase: .paused),
          observation: F.observation(F.snapshot(F.request())),
          action: .merge, phase: .merging),
    // Rule 3
    .init(testDescription: "auto-fix off never dispatches or escalates",
          record: F.record(autoFix: false),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing])), session: .missing),
          action: .wait, phase: .watching),
    .init(testDescription: "auto-fix off still notifies ready while the owner is busy",
          record: stable(autoFix: false),
          observation: F.observation(F.snapshot(F.request()), session: .busy),
          action: .notifyReady, phase: .watching),
    // Rules 4 and 5
    .init(testDescription: "archived owner escalates",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing])), session: .archived),
          action: .escalate(.ownerGone), phase: .escalated(.ownerGone)),
    .init(testDescription: "missing owner escalates",
          record: F.record(), observation: F.observation(F.snapshot(F.request()), session: .missing),
          action: .escalate(.ownerGone), phase: .escalated(.ownerGone)),
    .init(testDescription: "busy owner waits",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing])), session: .busy),
          action: .wait, phase: .watching),
    // Rule 6
    .init(testDescription: "fixing with an idle owner moves to awaitingPush",
          record: F.record(phase: .fixing(dispatchedAt: F.earlier), fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.now, pollsWithoutProgress: 1)),
    .init(testDescription: "third poll without progress escalates",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 2), fixAttempts: 1,
                           lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .escalate(.noProgress), phase: .escalated(.noProgress)),
    .init(testDescription: "a new head is progress and redispatches remaining failures",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(head: F.newHead, checks: [F.failing]), localHead: F.newHead)),
          action: .dispatchFix(failingOnly), phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "a reply on a dispatched thread is progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly)),
          observation: F.observation(F.snapshot(F.request(threads: [repliedThread]))),
          action: .wait, phase: .watching),
    .init(testDescription: "awaitingPush with a pending check holds without counting",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1), fixAttempts: 1,
                           lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1)),
    .init(testDescription: "an untrusted non-viewer comment on a dispatched thread is not progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly)),
          observation: F.observation(F.snapshot(F.request(threads: [driveByThread]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1)),
    // Rule 7
    .init(testDescription: "problems already dispatched wait",
          record: F.record(fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .wait, phase: .watching),
    .init(testDescription: "a new trusted comment in a dispatched thread redispatches",
          record: F.record(fixAttempts: 1, lastDispatched: F.fingerprint(threadOnly)),
          observation: F.observation(F.snapshot(F.request(threads: [followUpThread]))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [followUpThread])),
          phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "trusted thread dispatches while checks are pending",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.pending], threads: [F.trustedThread]))),
          action: .dispatchFix(threadOnly), phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "failed check waits for pending checks",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .wait, phase: .watching),
    .init(testDescription: "untrusted thread is ignored",
          record: F.record(), observation: F.observation(F.snapshot(F.request(threads: [F.thread("PRRT_2", trust: .untrusted)]))),
          action: .wait, phase: .watching),
    .init(testDescription: "conflict, checks and threads dispatch together",
          record: F.record(),
          observation: F.observation(F.snapshot(F.request(mergeState: .dirty, checks: [F.failing], threads: [F.trustedThread]))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: true, failingChecks: [F.failing], threads: [F.trustedThread])),
          phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "attempt cap escalates",
          record: F.record(fixAttempts: 3), observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .escalate(.attemptsExhausted), phase: .escalated(.attemptsExhausted)),
    // Rule 8
    .init(testDescription: "merges when the gate passes",
          record: stable(autoMerge: true), observation: F.observation(F.snapshot(F.request())),
          action: .merge, phase: .merging),
    .init(testDescription: "required reviewer missing on the head blocks merge",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: codexRules, headReviewers: ["maintainer"]),
          action: .wait, phase: .watching),
    .init(testDescription: "required reviewer on the head allows merge",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: codexRules, headReviewers: ["chatgpt-codex-connector"]),
          action: .merge, phase: .merging),
    .init(testDescription: "unknown head reviewers block merge when rules require one",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: codexRules, headReviewers: nil),
          action: .wait, phase: .watching),
    .init(testDescription: "one stable poll is not enough",
          record: F.record(autoMerge: true), observation: F.observation(F.snapshot(F.request())),
          action: .wait, phase: .watching),
    .init(testDescription: "dirty local tree blocks merge",
          record: stable(autoMerge: true), observation: F.observation(F.snapshot(F.request(), dirty: true)),
          action: .wait, phase: .watching),
    .init(testDescription: "local head behind the provider blocks merge",
          record: stable(autoMerge: true), observation: F.observation(F.snapshot(F.request(), localHead: F.newHead)),
          action: .wait, phase: .watching),
    .init(testDescription: "merge queue accepts a blocked merge state",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(mergeState: .blocked, isMergeQueueEnabled: true))),
          action: .merge, phase: .merging),
    .init(testDescription: "queued record waits while in the queue",
          record: F.record(phase: .queued, autoMerge: true),
          observation: F.observation(F.snapshot(F.request(isMergeQueueEnabled: true, isInMergeQueue: true))),
          action: .wait, phase: .queued),
    // Review focus: inputs right after a push and reviewer-name spelling
    .init(testDescription: "a new head with no checks registered yet does not merge",
          record: F.record(autoMerge: true, lastSeenHead: "0ld", stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .wait, phase: .watching),
    .init(testDescription: "unknown mergeability neither dispatches a conflict fix nor merges",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(mergeState: .unknown))),
          action: .wait, phase: .watching),
    .init(testDescription: "a cancelled run neither dispatches nor merges",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(checks: [F.check("build", .cancel)]))),
          action: .wait, phase: .watching),
    .init(testDescription: "required reviewers match case-insensitively",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request()), rules: mixedCaseRules, headReviewers: ["chatgpt-codex-connector"]),
          action: .merge, phase: .merging),
    .init(testDescription: "an outdated trusted thread is ignored",
          record: F.record(),
          observation: F.observation(F.snapshot(F.request(threads: [outdatedThread]))),
          action: .wait, phase: .watching),
]

@Suite struct ShepherdPolicyTests {
    @Test("decides the action and next phase", arguments: policyCases)
    func decide(_ c: ShepherdPolicyCase) {
        let decision = ShepherdPolicy.decide(c.record, c.observation)
        #expect(decision.action == c.action)
        #expect(decision.record.phase == c.phase)
    }

    @Test("dispatch counts the attempt and stores the fingerprint")
    func dispatchUpdatesRecord() {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 1),
            F.observation(F.snapshot(F.request(checks: [F.failing])))
        )
        #expect(decision.record.fixAttempts == 2)
        #expect(decision.record.lastDispatchedFingerprint == ShepherdFingerprint(
            headSHA: F.head, hasConflict: false, failingCheckIDs: ["unit-tests"], threadIDs: []
        ))
        #expect(decision.record.updatedAt == F.now)
    }

    @Test("a recurring identical failure after a conclusive green redispatches")
    func recurringFailureRedispatches() {
        let green = ShepherdPolicy.decide(
            F.record(fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
            F.observation(F.snapshot(F.request()))
        )
        #expect(green.record.fixAttempts == 0)
        #expect(green.record.lastDispatchedFingerprint == nil)

        let again = ShepherdPolicy.decide(green.record, F.observation(F.snapshot(F.request(checks: [F.failing]))))
        #expect(again.action == .dispatchFix(failingOnly))
        #expect(again.record.fixAttempts == 1)
    }

    @Test("fix attempts reset only once checks are green", arguments: [
        (ReviewCheckBucket.pass, 0),
        (.pending, 2),
    ] as [(ReviewCheckBucket, Int)])
    func attemptsReset(bucket: ReviewCheckBucket, expected: Int) {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 2),
            F.observation(F.snapshot(F.request(checks: [F.check("build", bucket)])))
        )
        #expect(decision.record.fixAttempts == expected)
    }

    @Test("head stability counts consecutive complete polls on one head", arguments: stabilityCases)
    func headStability(_ c: ShepherdStabilityCase) {
        let decision = ShepherdPolicy.decide(
            F.record(autoFix: false, lastSeenHead: c.lastSeen, stablePolls: c.polls),
            F.observation(F.snapshot(F.request(checks: [F.check("build", c.bucket)])))
        )
        #expect(decision.record.stableHeadPolls == c.expected)
        #expect(decision.record.lastSeenHeadSHA == F.head)
    }

    @Test("ready notification fires once per head")
    func readyOncePerHead() {
        let observation = F.observation(F.snapshot(F.request()))
        let first = ShepherdPolicy.decide(stable(), observation)
        let second = ShepherdPolicy.decide(first.record, observation)
        #expect(first.action == .notifyReady)
        #expect(first.record.notifiedReadyHeadSHA == F.head)
        #expect(second.action == .wait)

        let moved = F.observation(F.snapshot(F.request(head: F.newHead), localHead: F.newHead))
        let third = ShepherdPolicy.decide(second.record, moved)
        let fourth = ShepherdPolicy.decide(third.record, moved)
        #expect(third.action == .wait)
        #expect(fourth.action == .notifyReady)
        #expect(fourth.record.notifiedReadyHeadSHA == F.newHead)
    }

    @Test("merge outcome sets the next phase", arguments: [
        (ReviewMergeOutcome?.some(.merged), ShepherdPhase.merged),
        (.some(.queued), .queued),
        (nil, .watching),
    ] as [(ReviewMergeOutcome?, ShepherdPhase)])
    func mergeOutcome(outcome: ReviewMergeOutcome?, phase: ShepherdPhase) {
        let record = F.record(phase: .merging, autoMerge: true, lastSeenHead: F.head, stablePolls: 2)
        let next = ShepherdPolicy.applyMergeOutcome(outcome, to: record, now: F.now)
        #expect(next.phase == phase)
        #expect(next.finishedAt == (outcome == .merged ? F.now : nil))
        #expect(next.stableHeadPolls == (outcome == nil ? 0 : 2))
        #expect(next.updatedAt == F.now)
    }
}
