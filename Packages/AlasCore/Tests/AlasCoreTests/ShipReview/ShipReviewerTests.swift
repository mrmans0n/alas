import Foundation
import Testing
import AlasModel
@testable import AlasIntegrations

private let t0 = Date(timeIntervalSince1970: 1_000)
private let fileURL = URL(fileURLWithPath: "/memory/ship-reviews.json")
private let id = ShipReviewID(worktreeID: "wt-1", sessionID: "s1")
private let pullRequest = ShipReviewTarget.pullRequest(PendingPRPush(title: "Add b", body: "Body", draft: false, base: "main"))

private let diff = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -1,1 +1,2 @@
     let a = 1
    +let b = 2
    """
private let approve = #"{"verdict": "approve", "summary": "Looks right.", "findings": [], "resolved": []}"#
private let oneFinding = #"""
    {"verdict": "request_changes", "summary": "One bug.",
     "findings": [{"path": "Sources/A.swift", "line": 2, "body": "b is never read."}], "resolved": []}
    """#

/// Effects that record every call and answer from what the test set.
@MainActor
private final class FakeEffects {
    struct Push: Equatable {
        let target: ShipReviewTarget
        let headSHA: String
    }

    var head = "h1"
    /// Thrown by every HEAD read when set.
    var headError: (any Error)?
    var label: String? = "Codex"
    var instructionsError: (any Error)?
    /// The reviewer's final messages, in order; approve once they run out.
    var replies: [String] = []
    var openFindings = 1
    /// Per review session; nil reads `openFindings` for every session.
    var openFindingsIn: ((ReviewSessionID) -> Int?)?
    var autoFix = true
    var reviewBeforePush = true
    /// The top entry a stack plan publishes, below HEAD; nil reads HEAD for every target.
    var stackTop: String?
    /// Runs inside the push effect, as `pr_create` re-entering the gate does.
    var onPush: ((ShipReviewID, ShipReviewTarget, String) -> Void)?
    /// Runs while a findings delivery waits on the owning session.
    var duringDelivery: (() -> Void)?
    /// What each delivery's `isStillWanted` said once the session was ready.
    var stillWanted: [Bool] = []

    var runs: [ShipReviewer.ReviewerRun] = []
    var filings: [ShipReviewer.Filing] = []
    var delivered: [ShepherdPrompt] = []
    var pushes: [Push] = []
    var stops: [ShipReviewStop] = []
    var discarded: [String] = []
    var removedCheckouts: [ShipReviewID] = []

    func effects() -> ShipReviewer.Effects {
        var shipHead: (@MainActor (ShipReviewID, ShipReviewTarget?) async throws -> String)?
        if let top = stackTop {
            shipHead = { _, target in
                if case .stack = target { return top }
                return self.head
            }
        }
        return ShipReviewer.Effects(
            context: { _ in
                ShipReviewer.Context(
                    worktreePath: URL(fileURLWithPath: "/tmp/wt-1"), branch: "feature", baseBranch: "main",
                    providerName: "GitHub", projectSettings: nil
                )
            },
            settings: { (CodeReviewSettings(), ShepherdDefaults(reviewBeforePush: self.reviewBeforePush)) },
            ownerAgentID: { _ in "codex" },
            agentLabel: { _ in self.label },
            git: ShipReviewGit(
                headSHA: { _ in
                    if let error = await self.headError { throw error }
                    return await self.head
                },
                mergeBase: { _, _, _ in "base0" },
                diff: { _, _, _ in diff }
            ),
            instructions: { _, _ in
                if let error = self.instructionsError { throw error }
                return CodeReviewInstructions()
            },
            runReviewer: { run in
                self.runs.append(run)
                let reply = self.replies.isEmpty ? approve : self.replies.removeFirst()
                return .finished(sessionID: "reviewer-\(self.runs.count)", finalText: reply)
            },
            discardReviewer: { _, sessionID in self.discarded.append(sessionID) },
            earlierFindings: { sessionIDs in
                self.filings.enumerated()
                    .filter { sessionIDs.contains(Self.reviewSessionID($0.offset)) }
                    .flatMap { zip($0.element.findingIDs, $0.element.result.findings) }
                    .map { CodeReviewEarlierFinding(id: $0, path: $1.path, line: nil, body: $1.body, replies: []) }
            },
            openFindingCount: { sessionID in
                if let count = self.openFindingsIn { return count(sessionID) }
                return self.openFindings
            },
            fileRound: { filing in
                self.filings.append(filing)
                return Self.reviewSessionID(self.filings.count - 1)
            },
            deliverFindings: { _, prompt, isStillWanted in
                self.duringDelivery?()
                self.stillWanted.append(isStillWanted())
                self.delivered.append(prompt)
                return .delivered
            },
            push: { id, target, headSHA in
                self.pushes.append(Push(target: target, headSHA: headSHA))
                self.onPush?(id, target, headSHA)
                return nil
            },
            autoFix: { _ in self.autoFix },
            localCommitsToPush: { _ in nil },
            notify: { _, stop in self.stops.append(stop) },
            shipHead: shipHead,
            removeReviewCheckout: { id in self.removedCheckouts.append(id) }
        )
    }

    static func reviewSessionID(_ index: Int) -> ReviewSessionID {
        ReviewSessionID(rawValue: "review-\(index + 1)")
    }
}

@MainActor
struct ShipReviewerTests {
    private func makeReviewer(_ fake: FakeEffects, store: MemoryStore = MemoryStore()) -> ShipReviewer {
        let reviewer = ShipReviewer(store: store, fileURL: fileURL, now: { t0 })
        reviewer.effects = fake.effects()
        return reviewer
    }

    @Test func cleanReviewPushesTheReviewedSHA() async {
        let fake = FakeEffects()
        let reviewer = makeReviewer(fake)
        var reentered: [ShipReviewer.Gate] = []
        fake.onPush = { id, target, headSHA in
            reentered.append(reviewer.requestPush(id, target: target, headSHA: headSHA))
        }

        #expect(reviewer.requestPush(id, target: pullRequest, headSHA: "h1") != .push)
        await reviewer.settle()

        #expect(fake.pushes == [.init(target: pullRequest, headSHA: "h1")])
        #expect(reentered == [.push])
        #expect(fake.filings.map(\.round) == [1])
        let record = reviewer.record(for: id)
        #expect(record?.phase == .idle)
        #expect(record?.passedSHAs == ["h1"])
    }

    /// A partial stack ship reviews the top entry its plan publishes, not
    /// HEAD above it: a clean review pushes once instead of restarting.
    @Test func partialStackShipPushesOnceAfterACleanReview() async {
        let fake = FakeEffects()
        fake.head = "top"
        fake.stackTop = "e2"
        let reviewer = makeReviewer(fake)
        let stack = ShipReviewTarget.stack(
            StackShipPlan(shipThroughEntryID: "e2", shipThroughTitle: "Second", opensDrafts: false), base: "main"
        )
        var reentered: [ShipReviewer.Gate] = []
        fake.onPush = { id, target, headSHA in
            reentered.append(reviewer.requestPush(id, target: target, headSHA: headSHA))
        }

        #expect(reviewer.requestPush(id, target: stack, headSHA: "e2") != .push)
        await reviewer.settle()

        #expect(fake.runs.count == 1)
        #expect(fake.pushes == [.init(target: stack, headSHA: "e2")])
        #expect(reentered == [.push])
        #expect(reviewer.record(for: id)?.phase == .idle)
        #expect(reviewer.record(for: id)?.passedSHAs == ["e2"])
    }

    @Test func findingsGoToTheOwnerAndTheNextCommitStartsRoundTwo() async throws {
        let fake = FakeEffects()
        fake.replies = [oneFinding]
        let reviewer = makeReviewer(fake)

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()

        #expect(fake.delivered.map(\.card.title) == ["Review before push · 1 finding"])
        #expect(reviewer.record(for: id)?.phase == .awaitingFix(headSHA: "h1"))
        #expect(fake.pushes.isEmpty)

        fake.head = "h2"
        reviewer.ownerTurnCompleted(sessionID: id.sessionID)
        await reviewer.settle()

        let findingID = try #require(fake.filings.first?.findingIDs.first)
        #expect(fake.runs.count == 2)
        #expect(fake.runs.last?.reuseSessionID == "reviewer-1")
        #expect(fake.runs.last?.prompt.contains(findingID) == true)
        #expect(fake.filings.last?.earlierRoundSessionIDs == [FakeEffects.reviewSessionID(0)])
        #expect(fake.pushes.map(\.headSHA) == ["h2"])
    }

    /// A later round need not report an earlier round's findings fixed: an
    /// owner turn without a commit pushes only once none of this push's
    /// findings is open, and a session it can't read counts as open.
    @Test(arguments: [1, nil] as [Int?])
    func ownerTurnWithoutCommitWaitsForEveryRoundsFindings(earlierRoundOpen: Int?) async {
        let fake = FakeEffects()
        fake.replies = [oneFinding, oneFinding]
        fake.openFindingsIn = { $0 == FakeEffects.reviewSessionID(0) ? earlierRoundOpen : 0 }
        let reviewer = makeReviewer(fake)

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()
        fake.head = "h2"
        reviewer.ownerTurnCompleted(sessionID: id.sessionID)
        await reviewer.settle()
        #expect(reviewer.record(for: id)?.phase == .awaitingFix(headSHA: "h2"))

        // Round two's finding is resolved; the turn ends without a commit.
        reviewer.ownerTurnCompleted(sessionID: id.sessionID)
        await reviewer.settle()

        let stop = ShipReviewStop.noProgress(openFindings: 1)
        #expect(reviewer.record(for: id)?.phase == .stopped(stop))
        #expect(fake.stops == [stop])
        #expect(fake.pushes.isEmpty)
    }

    /// A fix the owner commits after a review of a pushed head isn't on the
    /// remote: the clean review publishes it through `pr_create`.
    @Test func fixAfterAPushedHeadReviewIsPublished() async {
        let fake = FakeEffects()
        fake.replies = [oneFinding]
        let reviewer = makeReviewer(fake)
        reviewer.prepare(id, enabled: true, reviewer: nil)

        reviewer.reviewPushedHead(id, headSHA: "h1")
        await reviewer.settle()
        #expect(reviewer.record(for: id)?.phase == .awaitingFix(headSHA: "h1"))
        fake.head = "h2"
        reviewer.ownerTurnCompleted(sessionID: id.sessionID)
        await reviewer.settle()

        let publish = ShipReviewTarget.pullRequest(PendingPRPush(title: "", body: "", draft: false, base: nil))
        #expect(fake.pushes == [.init(target: publish, headSHA: "h2")])
        #expect(reviewer.record(for: id)?.passedSHAs == ["h2"])
    }

    /// `pr_create` adopting an open request with nothing to push: with the
    /// default lever on, the adopted head is reviewed before it can merge.
    @Test(arguments: [true, false])
    func adoptedHeadIsReviewedWhenTheDefaultLeverIsOn(leverOn: Bool) async {
        let fake = FakeEffects()
        fake.reviewBeforePush = leverOn
        let reviewer = makeReviewer(fake)

        reviewer.seedRecord(id)
        let gate = reviewer.reviewGate(worktreeID: id.worktreeID, sessionID: id.sessionID)
        reviewer.reviewPushedHead(id, headSHA: "h1")
        await reviewer.settle()

        if leverOn {
            #expect(gate?.passedSHAs.isEmpty == true)
            #expect(fake.runs.count == 1)
            #expect(reviewer.record(for: id)?.passedSHAs == ["h1"])
        } else {
            #expect(gate == nil)
            #expect(reviewer.record(for: id) == nil)
            #expect(fake.runs.isEmpty)
        }
    }

    /// Picking a reviewer for a PR that has no record yet keeps the lever
    /// the Settings default shows instead of turning it off.
    @Test(arguments: [true, false])
    func changingTheReviewerKeepsTheDefaultLever(leverOn: Bool) {
        let fake = FakeEffects()
        fake.reviewBeforePush = leverOn
        let reviewer = makeReviewer(fake)

        reviewer.setReviewer(.agent(id: "codex", modelID: "gpt-5.2"), for: id)

        #expect(reviewer.record(for: id)?.enabled == leverOn)
        #expect(reviewer.record(for: id)?.reviewer == .agent(id: "codex", modelID: "gpt-5.2"))
    }

    /// A remote head Alas couldn't review is checked again: once the
    /// worktree checks it out, it is reviewed.
    @Test func unreviewedRemoteHeadIsReviewedOnceCheckedOut() async {
        let fake = FakeEffects()
        fake.head = "local"
        let reviewer = makeReviewer(fake)
        reviewer.prepare(id, enabled: true, reviewer: nil)

        reviewer.reviewPushedHead(id, headSHA: "remote")
        await reviewer.settle()
        #expect(reviewer.record(for: id)?.unreviewedRemoteHead == "remote")
        #expect(fake.runs.isEmpty)

        fake.head = "remote"
        reviewer.reviewPushedHead(id, headSHA: "remote")
        await reviewer.settle()

        #expect(fake.runs.count == 1)
        #expect(reviewer.record(for: id)?.passedSHAs == ["remote"])
        #expect(reviewer.record(for: id)?.unreviewedRemoteHead == nil)
    }

    @Test func unreadableBranchAfterTheOwnersTurnStops() async {
        struct GitFailed: LocalizedError {
            var errorDescription: String? { "git failed" }
        }
        let fake = FakeEffects()
        fake.replies = [oneFinding]
        let reviewer = makeReviewer(fake)

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()
        fake.headError = GitFailed()
        reviewer.ownerTurnCompleted(sessionID: id.sessionID)
        await reviewer.settle()

        let stop = ShipReviewStop.reviewerFailed("couldn't read the branch: git failed")
        #expect(reviewer.record(for: id)?.phase == .stopped(stop))
        #expect(fake.stops == [stop])
        #expect(fake.pushes.isEmpty)
    }

    @Test func sendToSessionDeliversTheStoppedRoundsFindings() async throws {
        let fake = FakeEffects()
        fake.replies = [oneFinding]
        fake.autoFix = false
        let reviewer = makeReviewer(fake)

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()
        #expect(reviewer.record(for: id)?.phase == .stopped(.findingsWithAutoFixOff(count: 1)))
        #expect(fake.delivered.isEmpty)

        reviewer.sendFindings(id)
        await reviewer.settle()

        let findingID = try #require(fake.filings.first?.findingIDs.first)
        #expect(fake.delivered.map(\.card.title) == ["Review before push · 1 finding"])
        #expect(fake.delivered.first?.text.contains(findingID) == true)
        #expect(reviewer.record(for: id)?.phase == .awaitingFix(headSHA: "h1"))
        #expect(fake.pushes.isEmpty)
    }

    /// "Stop" ends this push's reviewer session, then removes its checkout.
    @Test func stopDiscardsTheReviewerAndItsCheckout() async {
        let fake = FakeEffects()
        fake.replies = [oneFinding]
        let reviewer = makeReviewer(fake)
        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()
        #expect(fake.removedCheckouts.isEmpty)

        reviewer.cancel(id)
        await reviewer.settle()

        #expect(fake.discarded == ["reviewer-1"])
        #expect(fake.removedCheckouts == [id])
    }

    @Test func unavailableReviewerStopsWithoutPushing() async {
        let fake = FakeEffects()
        fake.label = nil
        let reviewer = makeReviewer(fake)

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()

        let stop = ShipReviewStop.reviewerFailed("codex isn't available")
        #expect(reviewer.record(for: id)?.phase == .stopped(stop))
        #expect(fake.stops == [stop])
        #expect(fake.runs.isEmpty)
        #expect(fake.pushes.isEmpty)
    }

    @Test func unreadableInstructionsStopWithoutPushing() async {
        let fake = FakeEffects()
        fake.instructionsError = ShepherdRulesReadError(file: ".alas/code-review.md", host: "local", detail: "denied")
        let reviewer = makeReviewer(fake)

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()

        let stop = ShipReviewStop.instructionsUnreadable(".alas/code-review.md: denied")
        #expect(reviewer.record(for: id)?.phase == .stopped(stop))
        #expect(fake.stops == [stop])
        #expect(fake.runs.isEmpty)
        #expect(fake.pushes.isEmpty)
    }

    @Test func relaunchRestartsARunningRoundOnce() async throws {
        let store = MemoryStore()
        var running = ShipReviewRecord(id: id, enabled: true, reviewer: nil, maxRounds: 3, now: t0)
        running.pending = pullRequest
        running.roundsThisPush = 1
        running.rounds = [
            ShipReviewRound(
                number: 1, headSHA: "h0", reviewSessionID: FakeEffects.reviewSessionID(0), verdict: .requestChanges,
                openFindingIDs: ["f1"], reviewerLabel: "Codex", reviewedAt: t0
            ),
            ShipReviewRound(number: 2, headSHA: "h1", reviewerLabel: "Codex"),
        ]
        running.phase = .reviewing(headSHA: "h1", startedAt: t0)
        running.reviewerSessionID = "reviewer-before-quit"
        try store.write(ShipReviewsFile(records: [running]), to: fileURL)
        let fake = FakeEffects()
        let reviewer = makeReviewer(fake, store: store)

        reviewer.start()
        reviewer.start()

        let restarted = try #require(reviewer.record(for: id))
        #expect(restarted.phase == .reviewing(headSHA: "h1", startedAt: t0))
        #expect(restarted.roundsThisPush == 1)
        #expect(restarted.rounds.map(\.number) == [1, 2])
        #expect(restarted.reviewerSessionID == nil)
        await reviewer.settle()
        #expect(fake.runs.count == 1)
        #expect(fake.runs.first?.reuseSessionID == nil)
    }

    /// "Review again" after the round cap: the user asked, so the commit they
    /// made since is reviewed with a fresh allowance instead of stopping at once.
    @Test func reviewAgainAfterTheRoundCapReviewsTheNewHead() async throws {
        let store = MemoryStore()
        var exhausted = ShipReviewRecord(id: id, enabled: true, reviewer: nil, maxRounds: 3, now: t0)
        exhausted.pending = pullRequest
        exhausted.roundsThisPush = 3
        exhausted.rounds = (1...3).map {
            ShipReviewRound(
                number: $0, headSHA: "h1", reviewSessionID: FakeEffects.reviewSessionID($0 - 1), verdict: .requestChanges,
                openFindingIDs: ["f\($0)"], reviewerLabel: "Codex", reviewedAt: t0
            )
        }
        exhausted.phase = .stopped(.roundsExhausted(openFindings: 1))
        try store.write(ShipReviewsFile(records: [exhausted]), to: fileURL)
        let fake = FakeEffects()
        fake.head = "h2"
        let reviewer = makeReviewer(fake, store: store)
        reviewer.start()

        reviewer.retry(id)
        await reviewer.settle()

        #expect(fake.runs.count == 1)
        #expect(fake.pushes == [.init(target: pullRequest, headSHA: "h2")])
        #expect(reviewer.record(for: id)?.passedSHAs.contains("h2") == true)
    }

    /// Stopping the review while its findings wait on the owning session
    /// (hydrating, reattaching) keeps them from starting a fix turn.
    @Test func stoppedReviewFindingsAreNoLongerWanted() async {
        let fake = FakeEffects()
        fake.replies = [oneFinding]
        let reviewer = makeReviewer(fake)
        fake.duringDelivery = { reviewer.cancel(id) }

        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()

        #expect(fake.stillWanted == [false])
        #expect(fake.pushes.isEmpty)
    }

    /// A round that requests changes only in its summary (its findings sit
    /// outside the diff) can still be sent to the session after a stop.
    @Test func summaryOnlyFindingsCanBeSentToTheSession() async {
        let fake = FakeEffects()
        fake.autoFix = false
        fake.openFindings = 0
        fake.replies = [#"""
            {"verdict": "request_changes", "summary": "The migration is missing.",
             "findings": [{"path": "Migrations/001.sql", "line": 1, "body": "Add the column."}], "resolved": []}
            """#]
        let reviewer = makeReviewer(fake)
        _ = reviewer.requestPush(id, target: pullRequest, headSHA: "h1")
        await reviewer.settle()
        guard case .stopped = reviewer.record(for: id)?.phase else {
            Issue.record("expected a stop, got \(String(describing: reviewer.record(for: id)?.phase))")
            return
        }
        #expect(fake.delivered.isEmpty)

        reviewer.sendFindings(id)
        await reviewer.settle()

        #expect(fake.delivered.count == 1)
        #expect(fake.stillWanted == [true])
        #expect(reviewer.record(for: id)?.phase == .awaitingFix(headSHA: "h1"))
    }

    /// A headless host sharing the app's profile leaves a worktree it doesn't
    /// serve to the app: its interrupted round is neither restarted nor stopped.
    @Test func startLeavesReviewsOfUnservedWorktreesAlone() async throws {
        let store = MemoryStore()
        var running = ShipReviewRecord(id: id, enabled: true, reviewer: nil, maxRounds: 3, now: t0)
        running.pending = pullRequest
        running.rounds = [ShipReviewRound(number: 1, headSHA: "h1", reviewerLabel: "Codex")]
        running.phase = .reviewing(headSHA: "h1", startedAt: t0)
        try store.write(ShipReviewsFile(records: [running]), to: fileURL)
        let fake = FakeEffects()
        let reviewer = makeReviewer(fake, store: store)
        reviewer.effects?.servesWorktree = { _ in false }

        reviewer.start()
        reviewer.ownerTurnCompleted(sessionID: id.sessionID)
        await reviewer.settle()

        #expect(fake.runs.isEmpty)
        #expect(reviewer.record(for: id) == running)
    }
}
