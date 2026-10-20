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
    .init(lastSeen: F.head, polls: 1, bucket: .unknown, expected: 0),
    .init(lastSeen: "0ld", polls: 1, bucket: .pass, expected: 1),
    .init(lastSeen: "0ld", polls: 1, bucket: .pending, expected: 0),
]

/// A head clock started exactly `noChecksGracePeriod` before `F.now`.
private let graceElapsed = F.now.addingTimeInterval(-ShepherdPolicy.noChecksGracePeriod)

struct ShepherdHeadClockCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let lastSeen: String?
    let firstSeen: Date?
    let head: String?
    let expected: Date?
}

private let headClockCases: [ShepherdHeadClockCase] = [
    .init(testDescription: "a new head restarts the clock",
          lastSeen: "0ld", firstSeen: graceElapsed, head: F.head, expected: F.now),
    .init(testDescription: "the same head keeps its clock",
          lastSeen: F.head, firstSeen: graceElapsed, head: F.head, expected: graceElapsed),
    .init(testDescription: "a record saved without a clock starts it",
          lastSeen: F.head, firstSeen: nil, head: F.head, expected: F.now),
    .init(testDescription: "no provider head clears the clock",
          lastSeen: F.head, firstSeen: graceElapsed, head: nil, expected: nil),
]

private let failingOnly = ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing], threads: [])
private let threadOnly = ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [F.trustedThread])
private let uiFailing = F.check("ui-tests", .fail)
/// Revision of `F.trustedThread` and every reply variant below.
private let threadRevision = "PRRT_1#PRRT_1-c1"
/// Same head comment as `F.trustedThread`, so only the reply differs.
private let repliedThread = F.thread("PRRT_1", comments: [
    F.comment("PRRT_1-c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "me", body: "Backoff already lives in RetryPolicy.", trust: .untrusted, viewer: true),
])
private let secondReplyThread = F.thread("PRRT_1", comments: [
    F.comment("PRRT_1-c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "me", body: "Backoff already lives in RetryPolicy.", trust: .untrusted, viewer: true),
    F.comment("c4", author: "me", body: "Uploads now share it too.", trust: .untrusted, viewer: true),
])
private let replyThenDriveByThread = F.thread("PRRT_1", comments: [
    F.comment("PRRT_1-c1", author: "maintainer", body: "Please back off.", trust: .trusted),
    F.comment("c2", author: "me", body: "Backoff already lives in RetryPolicy.", trust: .untrusted, viewer: true),
    F.comment("c3", author: "passerby", body: "+1", trust: .untrusted),
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
    .init(testDescription: "a new viewer reply on a dispatched thread is progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly), viewerCommentIDs: []),
          observation: F.observation(F.snapshot(F.request(threads: [repliedThread]))),
          action: .wait, phase: .watching),
    .init(testDescription: "a viewer reply that existed at dispatch is not progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly), viewerCommentIDs: ["c2"]),
          observation: F.observation(F.snapshot(F.request(threads: [repliedThread]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1)),
    .init(testDescription: "a viewer reply id not seen at dispatch is progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly), viewerCommentIDs: ["c2"]),
          observation: F.observation(F.snapshot(F.request(threads: [secondReplyThread]))),
          action: .wait, phase: .watching),
    .init(testDescription: "a viewer reply followed by an untrusted comment is progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly), viewerCommentIDs: []),
          observation: F.observation(F.snapshot(F.request(threads: [replyThenDriveByThread]))),
          action: .wait, phase: .watching),
    .init(testDescription: "awaitingPush with a pending check holds without counting",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1), fixAttempts: 1,
                           lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1)),
    .init(testDescription: "an unrelated pending check does not freeze a thread-only awaitingPush",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 2), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.pending], threads: [F.trustedThread]))),
          action: .escalate(.noProgress), phase: .escalated(.noProgress)),
    .init(testDescription: "awaitingPush escalates after the timeout while checks stay pending",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.now.addingTimeInterval(-ShepherdPolicy.awaitingPushTimeout),
                                                pollsWithoutProgress: 0),
                           fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .escalate(.noProgress), phase: .escalated(.noProgress)),
    .init(testDescription: "an incomplete thread list with missing threads is not progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly)),
          observation: F.observation(F.snapshot(F.request(threads: [], threadsComplete: false))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1)),
    .init(testDescription: "an untrusted non-viewer comment on a dispatched thread is not progress",
          record: F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                           lastDispatched: F.fingerprint(threadOnly), viewerCommentIDs: []),
          observation: F.observation(F.snapshot(F.request(threads: [driveByThread]))),
          action: .wait, phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 1)),
    // Rule 7
    .init(testDescription: "a fingerprint left from an earlier turn does not hold back a fix",
          record: F.record(fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly)),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .dispatchFix(failingOnly), phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "a declined thread is not redispatched after a new head",
          record: F.record(fixAttempts: 1, handled: [threadRevision]),
          observation: F.observation(F.snapshot(F.request(head: F.newHead, threads: [repliedThread]), localHead: F.newHead)),
          action: .wait, phase: .watching),
    .init(testDescription: "trusted thread dispatches while checks are pending",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.pending], threads: [F.trustedThread]))),
          action: .dispatchFix(threadOnly), phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "failed check waits for pending checks",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.pending]))),
          action: .wait, phase: .watching),
    .init(testDescription: "a failed check next to an unknown check does not dispatch",
          record: F.record(), observation: F.observation(F.snapshot(F.request(checks: [F.failing, F.check("ci", .unknown)]))),
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
    .init(testDescription: "a record saved without a budget caps at the default",
          record: F.record(fixAttempts: 3, maxFixAttempts: nil),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .escalate(.attemptsExhausted), phase: .escalated(.attemptsExhausted)),
    .init(testDescription: "a raised budget keeps dispatching past the default",
          record: F.record(fixAttempts: 3, maxFixAttempts: 5),
          observation: F.observation(F.snapshot(F.request(checks: [F.failing]))),
          action: .dispatchFix(failingOnly), phase: .fixing(dispatchedAt: F.now)),
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
    .init(testDescription: "queued record dispatches a trusted thread that arrives while in the queue",
          record: F.record(phase: .queued, autoMerge: true, lastSeenHead: F.head, stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(
              threads: [F.trustedThread], isMergeQueueEnabled: true, isInMergeQueue: true
          ))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [F.trustedThread])),
          phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "queued record holds on an unchanged head without queue reporting",
          record: F.record(kind: .gitlab, phase: .queued, autoMerge: true, lastSeenHead: F.head, stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(kind: .gitlab))),
          action: .wait, phase: .queued),
    .init(testDescription: "queued record returns to watching on a new head without queue reporting",
          record: F.record(kind: .gitlab, phase: .queued, autoMerge: true, lastSeenHead: "0ld", stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(kind: .gitlab))),
          action: .wait, phase: .watching),
    .init(testDescription: "queued record leaves the queue and dispatches when its train pipeline is cancelled",
          record: F.record(kind: .gitlab, phase: .queued, autoMerge: true, lastSeenHead: F.head, stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(kind: .gitlab, checks: [F.check("train", .cancel)]))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [F.check("train", .cancel)], threads: [])),
          phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "queued record leaves the queue and dispatches when the request becomes conflicted",
          record: F.record(kind: .gitlab, phase: .queued, autoMerge: true, lastSeenHead: F.head, stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(kind: .gitlab, mergeState: .dirty))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: true, failingChecks: [], threads: [])),
          phase: .fixing(dispatchedAt: F.now)),
    .init(testDescription: "queued record merges again once a merge queue drops it",
          record: F.record(phase: .queued, autoMerge: true, lastSeenHead: F.head, stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(isMergeQueueEnabled: true))),
          action: .merge, phase: .merging),
    // Review focus: inputs right after a push and reviewer-name spelling
    .init(testDescription: "a new head with no checks registered yet does not merge",
          record: F.record(autoMerge: true, lastSeenHead: "0ld", stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .wait, phase: .watching),
    .init(testDescription: "a stable head with no checks waits out the grace period even with auto-merge",
          record: F.record(autoMerge: true, lastSeenHead: F.head, stablePolls: 2, headFirstSeen: F.earlier),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .wait, phase: .watching),
    .init(testDescription: "a stable head with no checks merges after the grace period",
          record: F.record(autoMerge: true, lastSeenHead: F.head, stablePolls: 2, headFirstSeen: graceElapsed),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .merge, phase: .merging),
    .init(testDescription: "a stable head with no checks and no head clock does not merge",
          record: F.record(autoMerge: true, lastSeenHead: F.head, stablePolls: 2),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .wait, phase: .watching),
    .init(testDescription: "a head with no checks inside the grace period is not announced ready",
          record: F.record(lastSeenHead: F.head, stablePolls: 2, headFirstSeen: F.earlier),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .wait, phase: .watching),
    .init(testDescription: "a head with no checks after the grace period is announced ready",
          record: F.record(lastSeenHead: F.head, stablePolls: 2, headFirstSeen: graceElapsed),
          observation: F.observation(F.snapshot(F.request(checks: []))),
          action: .notifyReady, phase: .watching),
    .init(testDescription: "a head with checks merges without a grace period",
          record: F.record(autoMerge: true, lastSeenHead: F.head, stablePolls: 2, headFirstSeen: F.now),
          observation: F.observation(F.snapshot(F.request())),
          action: .merge, phase: .merging),
    .init(testDescription: "unknown mergeability neither dispatches a conflict fix nor merges",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(mergeState: .unknown))),
          action: .wait, phase: .watching),
    .init(testDescription: "a cancelled run dispatches a fix and does not merge",
          record: stable(autoMerge: true),
          observation: F.observation(F.snapshot(F.request(checks: [F.check("build", .cancel)]))),
          action: .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [F.check("build", .cancel)], threads: [])),
          phase: .fixing(dispatchedAt: F.now)),
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
        #expect(decision.record.viewerCommentIDsAtDispatch == [])
        #expect(decision.record.updatedAt == F.now)
    }

    @Test("dispatch captures the viewer's existing comment ids")
    func dispatchCapturesViewerComments() {
        let decision = ShepherdPolicy.decide(F.record(), F.observation(F.snapshot(F.request(threads: [secondReplyThread]))))
        #expect(decision.action == .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [secondReplyThread])))
        #expect(decision.record.viewerCommentIDsAtDispatch == ["c2", "c4"])
    }

    @Test("a resolved thread reopened while an unrelated check is pending redispatches")
    func reopenedThreadRedispatches() {
        let resolved = ShepherdPolicy.decide(
            F.record(fixAttempts: 1, lastDispatched: F.fingerprint(threadOnly), viewerCommentIDs: []),
            F.observation(F.snapshot(F.request(checks: [F.pending])))
        )
        #expect(resolved.action == .wait)
        #expect(resolved.record.lastDispatchedFingerprint == nil)
        #expect(resolved.record.viewerCommentIDsAtDispatch == nil)
        #expect(resolved.record.fixAttempts == 1)

        let reopened = ShepherdPolicy.decide(
            resolved.record,
            F.observation(F.snapshot(F.request(checks: [F.pending], threads: [F.trustedThread])))
        )
        #expect(reopened.action == .dispatchFix(threadOnly))
        #expect(reopened.record.fixAttempts == 2)
    }

    @Test("partial clearance redispatches the survivors as the next attempt")
    func partialClearanceRedispatches() {
        let both = ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing, uiFailing], threads: [])
        let decision = ShepherdPolicy.decide(
            F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                     lastDispatched: F.fingerprint(both), viewerCommentIDs: []),
            F.observation(F.snapshot(F.request(checks: [F.check("unit-tests", .pass), uiFailing])))
        )
        #expect(decision.action == .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [uiFailing], threads: [])))
        #expect(decision.record.fixAttempts == 2)
    }

    @Test("a reply to the thread redispatches only the check left unfixed")
    func replyRedispatchesUnfixedCheck() {
        let mixed = ShepherdFixRequest(hasConflict: false, failingChecks: [F.failing], threads: [F.trustedThread])
        let decision = ShepherdPolicy.decide(
            F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 0), fixAttempts: 1,
                     lastDispatched: F.fingerprint(mixed), viewerCommentIDs: []),
            F.observation(F.snapshot(F.request(checks: [F.failing], threads: [repliedThread])))
        )
        #expect(decision.action == .dispatchFix(failingOnly))
        #expect(decision.record.fixAttempts == 2)
        #expect(decision.record.handledThreadRevisions == [threadRevision])
    }

    @Test("a new trusted comment on a handled thread redispatches it")
    func followUpOnHandledThreadRedispatches() {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 1, handled: [threadRevision]),
            F.observation(F.snapshot(F.request(threads: [followUpThread])))
        )
        #expect(decision.action == .dispatchFix(ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [followUpThread])))
        // The answered revision no longer exists, so it is forgotten.
        #expect(decision.record.handledThreadRevisions == nil)
    }

    @Test("only handled threads remaining counts as cleared")
    func handledThreadsCountAsCleared() {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 2, handled: [threadRevision]),
            F.observation(F.snapshot(F.request(threads: [repliedThread])))
        )
        #expect(decision.action == .wait)
        #expect(decision.record.fixAttempts == 0)
        #expect(decision.record.handledThreadRevisions == [threadRevision])
    }

    @Test("a recurring identical failure after a conclusive green redispatches")
    func recurringFailureRedispatches() {
        let green = ShepherdPolicy.decide(
            F.record(fixAttempts: 1, lastDispatched: F.fingerprint(failingOnly), viewerCommentIDs: []),
            F.observation(F.snapshot(F.request()))
        )
        #expect(green.record.fixAttempts == 0)
        #expect(green.record.lastDispatchedFingerprint == nil)
        #expect(green.record.viewerCommentIDsAtDispatch == nil)

        let again = ShepherdPolicy.decide(green.record, F.observation(F.snapshot(F.request(checks: [F.failing]))))
        #expect(again.action == .dispatchFix(failingOnly))
        #expect(again.record.fixAttempts == 1)
    }

    @Test("fix attempts reset only once checks are green", arguments: [
        ([F.check("build", .pass)], nil, 0),
        ([F.check("build", .pending)], nil, 2),
        ([], F.earlier, 2),
        ([], graceElapsed, 0),
    ] as [([ReviewCheck], Date?, Int)])
    func attemptsReset(checks: [ReviewCheck], headFirstSeen: Date?, expected: Int) {
        let decision = ShepherdPolicy.decide(
            F.record(fixAttempts: 2, lastSeenHead: F.head, headFirstSeen: headFirstSeen),
            F.observation(F.snapshot(F.request(checks: checks)))
        )
        #expect(decision.record.fixAttempts == expected)
    }

    @Test("changing the budget resumes only a record that ran out of attempts below it", arguments: [
        (ShepherdPhase.escalated(.attemptsExhausted), 5, ShepherdPhase.watching, 5),
        (.escalated(.attemptsExhausted), 3, .escalated(.attemptsExhausted), 3),
        (.escalated(.noProgress), 5, .escalated(.noProgress), 5),
        (.escalated(.attemptsExhausted), 99, .watching, ShepherdPolicy.fixAttemptRange.upperBound),
    ] as [(ShepherdPhase, Int, ShepherdPhase, Int)])
    func budgetChange(phase: ShepherdPhase, budget: Int, expectedPhase: ShepherdPhase, expectedBudget: Int) {
        var record = F.record(phase: phase, fixAttempts: 3)
        record.setFixAttemptBudget(budget)
        #expect(record.phase == expectedPhase)
        #expect(record.fixAttemptBudget == expectedBudget)
        #expect(record.fixAttempts == 3)
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

    @Test("the no-checks clock follows the provider head", arguments: headClockCases)
    func headClock(_ c: ShepherdHeadClockCase) {
        let decision = ShepherdPolicy.decide(
            F.record(autoFix: false, lastSeenHead: c.lastSeen, stablePolls: 2, headFirstSeen: c.firstSeen),
            F.observation(F.snapshot(F.request(head: c.head, checks: [])))
        )
        #expect(decision.record.headFirstSeenAt == c.expected)
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
