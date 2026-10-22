import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore
@testable import AlasIntegrations

private typealias F = ShepherdFixtures

@MainActor
struct StackShepherdTests {
    // MARK: Fixtures

    nonisolated private static let local = ReviewLoopLocalState(
        branchName: "nacho/auth", headSHA: F.head, baseBranch: "main",
        hasWorkingTreeChanges: false, hasStagedChanges: false, aheadCommitCount: 2,
        hasUpstream: true, upstreamRemoteName: "origin", upstreamBranchName: "nacho/auth",
        needsPush: false
    )

    private static func request(
        _ number: Int,
        state: ReviewRequestState = .open,
        base: String = "main",
        head: String = F.head,
        checks: [ReviewCheck] = [F.check("build", .pass)],
        threads: [ReviewThread] = []
    ) -> ReviewRequest {
        let remote = F.remote()
        return ReviewRequest(
            remote: remote, number: number, title: "Entry \(number)", url: remote.reviewRequestURL(number: number),
            state: state, isDraft: false, headRefName: "nacho/auth--c-\(number)", baseRefName: base,
            headSHA: head, reviewDecision: .approved, mergeState: .clean,
            checks: checks, threads: threads, areThreadsComplete: true
        )
    }

    /// `numbers` bottom-up; GG-IDs are `c-<number>`.
    private static func stack(_ numbers: [Int]) -> GGStack {
        GGStack(
            name: "auth", base: "main", totalCommits: numbers.count, syncedCommits: numbers.count,
            currentPosition: numbers.count, behindBase: 0,
            entries: numbers.enumerated().map { index, number in
                GGStackEntry(position: index + 1, sha: "sha\(number)", title: "Entry \(number)", ggId: "c-\(number)", prNumber: number)
            }
        )
    }

    private static func record(_ numbers: [Int]) -> StackShepherdRecord {
        let empty = StackShepherdRecord(
            id: StackShepherdRecordID(worktreeID: "wt-1", stackName: "auth"),
            sessionID: "session-1", remote: F.remote(), base: "main", autoFix: true, entries: [], now: F.earlier
        )
        return StackShepherdPolicy.reconcile(empty, with: stack(numbers), now: F.earlier)
    }

    private static func observation(
        _ requests: [ReviewRequest],
        present: Set<String>? = nil,
        listed: Set<String>? = nil,
        canDispatch: Bool = true,
        isStackPublished: Bool = true,
        hasUnpublishedEntries: Bool? = nil,
        now: Date = F.now
    ) -> StackShepherdObservation {
        StackShepherdObservation(
            requests: Dictionary(uniqueKeysWithValues: requests.map { ($0.number, $0) }),
            presentEntryIDs: present,
            listedEntryIDs: listed,
            local: local,
            capabilities: .githubCLI,
            headReviewers: [:],
            session: .idle,
            canDispatch: canDispatch,
            isStackPublished: isStackPublished,
            hasUnpublishedEntries: hasUnpublishedEntries,
            rules: .none,
            now: now
        )
    }

    // MARK: Policy

    @Test func problemsInSeveralEntriesGoOutAsOneTurnBottomUp() {
        // gg lists the top entry first; the turn still starts at the bottom.
        var listed = Self.stack([41, 42, 43])
        listed = GGStack(
            name: listed.name, base: listed.base, totalCommits: 3, syncedCommits: 3,
            currentPosition: 3, behindBase: 0, entries: listed.entries.reversed()
        )
        let empty = StackShepherdRecord(
            id: StackShepherdRecordID(worktreeID: "wt-1", stackName: "auth"),
            sessionID: "session-1", remote: F.remote(), base: "main", autoFix: true, entries: [], now: F.earlier
        )
        let record = StackShepherdPolicy.reconcile(empty, with: listed, now: F.earlier)

        let decision = StackShepherdPolicy.decide(record, Self.observation([
            Self.request(41, checks: [F.failing]),
            Self.request(42),
            Self.request(43, threads: [F.trustedThread]),
        ]))

        #expect(decision.fixes.map(\.entry.position) == [1, 3])
        #expect(decision.record.entries.map { $0.shepherd.phase } == [
            .fixing(dispatchedAt: F.now), .watching, .fixing(dispatchedAt: F.now),
        ])
    }

    @Test func fixTurnWaitsWhileTheWorktreeCannotMoveBetweenEntries() {
        let decision = StackShepherdPolicy.decide(
            Self.record([41]),
            Self.observation([Self.request(41, checks: [F.failing])], canDispatch: false)
        )

        #expect(decision.fixes.isEmpty)
        #expect(decision.record.entries[0].shepherd.phase == .watching)
        #expect(decision.record.entries[0].shepherd.fixAttempts == 0)
    }

    @Test func readyIsAnnouncedOnceWhenEveryOpenEntryPasses() {
        let green = [Self.request(41), Self.request(42)]
        var record = Self.record([41, 42])
        // The head gate needs a head seen on consecutive polls.
        record = StackShepherdPolicy.decide(record, Self.observation(green, now: F.earlier)).record
        let pending = StackShepherdPolicy.decide(record, Self.observation([green[0], Self.request(42, checks: [F.pending])]))
        #expect(!pending.gatePasses)

        // Green requests say nothing about a commit gg has not published yet.
        let unpublished = StackShepherdPolicy.decide(record, Self.observation(green, isStackPublished: false))
        #expect(!unpublished.gatePasses && !unpublished.notifyReady)

        let ready = StackShepherdPolicy.decide(record, Self.observation(green))
        let again = StackShepherdPolicy.decide(ready.record, Self.observation(green))

        #expect(ready.gatePasses && ready.notifyReady)
        #expect(again.gatePasses && !again.notifyReady)
    }

    /// After a stack lands the worktree can move to a new one; the finished
    /// record only counts while the worktree is still on its own stack.
    @Test func aFinishedRecordDoesNotStandInForTheStackTheWorktreeMovedTo() throws {
        var finished = Self.record([41])
        finished.entries[0].shepherd.phase = .merged
        finished.finishedAt = Date()
        let fileURL = URL(fileURLWithPath: "/memory/stack-shepherds.json")
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [finished]), to: fileURL)
        let shepherd = StackShepherd(store: store, fileURL: fileURL)

        #expect(shepherd.record(forSession: "session-1", worktreeID: "wt-1", currentStackName: "auth")?.isFinished == true)
        #expect(shepherd.record(forSession: "session-1", worktreeID: "wt-1", currentStackName: "other") == nil)
        #expect(shepherd.record(forSession: "session-1", worktreeID: "wt-2", currentStackName: "auth") == nil)
    }

    @Test func reconcileKeepsEntryStateAcrossRewritesAndRestartsWhenTheRequestChanges() {
        var record = Self.record([41, 42])
        record.entries[0].shepherd.fixAttempts = 2
        record.entries[1].shepherd.fixAttempts = 2
        // Entry c-41 was rewritten (new SHA, now on top); c-42's request was
        // replaced by #50.
        let rewritten = GGStack(
            name: "auth", base: "main", totalCommits: 2, syncedCommits: 2, currentPosition: 2, behindBase: 0,
            entries: [
                GGStackEntry(position: 1, sha: "new42", title: "Entry 42", ggId: "c-42", prNumber: 50),
                GGStackEntry(position: 2, sha: "new41", title: "Entry 41", ggId: "c-41", prNumber: 41),
            ]
        )

        let next = StackShepherdPolicy.reconcile(record, with: rewritten, now: F.now)

        #expect(next.entries.map(\.requestNumber) == [50, 41])
        #expect(next.entries.map(\.position) == [1, 2])
        #expect(next.entries.map(\.shepherd.fixAttempts) == [0, 2])
    }

    @Test func entryBudgetFollowsTheStackAndRaisingItReopensExhaustedEntries() {
        var record = Self.record([41, 42])
        record.setFixAttemptBudget(1)
        record.entries[0].shepherd.fixAttempts = 1
        record.entries[0].shepherd.phase = .escalated(.attemptsExhausted)

        let added = StackShepherdPolicy.reconcile(record, with: Self.stack([41, 42, 43]), now: F.now)
        record.setFixAttemptBudget(2)

        #expect(added.entries[2].shepherd.fixAttemptBudget == 1)
        #expect(record.entries.map(\.shepherd.fixAttemptBudget) == [2, 2])
        #expect(record.entries[0].shepherd.phase == .watching)
        #expect(record.entries[0].shepherd.fixAttempts == 1)
    }

    @Test func aRetainedClosedEntryTakesABudgetChangeAndKeepsItsPhase() {
        var record = Self.record([41, 42, 43])
        record.entries[0].shepherd.phase = .closed
        record.entries[2].shepherd.phase = .merged

        record.setFixAttemptBudget(5)

        #expect(record.entries[0].shepherd.fixAttemptBudget == 5)
        #expect(record.entries[0].shepherd.phase == .closed)
        #expect(record.entries[1].shepherd.fixAttemptBudget == 5)
    }

    @Test func entriesGGNoLongerListsAreDroppedWhileOpenAndFinishWhenMerged() {
        let record = Self.record([41, 42, 43])

        let decision = StackShepherdPolicy.decide(record, Self.observation(
            [Self.request(41, state: .merged), Self.request(42), Self.request(43)],
            present: ["c-43"]
        ))

        #expect(decision.record.entries.map(\.requestNumber) == [41, 43])
        #expect(decision.record.entries[0].shepherd.phase == .merged)
        #expect(decision.finished == nil)

        let landed = StackShepherdPolicy.decide(decision.record, Self.observation([Self.request(43, state: .merged)]))
        #expect(landed.finished == .merged)
        #expect(landed.record.finishedAt == F.now)
    }

    /// Every tracked request merging is not the stack landing while gg still
    /// lists a local entry with no request: that work was never published.
    @Test func mergedRequestsDoNotFinishAStackThatStillHasUnpublishedWork() {
        let landed = [Self.request(41, state: .merged)]

        let waiting = StackShepherdPolicy.decide(Self.record([41]), Self.observation(landed, hasUnpublishedEntries: true))
        #expect(waiting.finished == nil)
        #expect(!waiting.record.isFinished)

        // Off the stack the record keeps what it last saw.
        let away = StackShepherdPolicy.decide(waiting.record, Self.observation(landed, hasUnpublishedEntries: nil))
        #expect(!away.record.isFinished)

        let published = StackShepherdPolicy.decide(waiting.record, Self.observation(landed, hasUnpublishedEntries: false))
        #expect(published.finished == .merged)
        #expect(published.record.isFinished)
    }

    /// A merged entry is landed, but a closed one never will be: gg land can't
    /// get past it, so the entries above it are not ready however green.
    @Test(arguments: [(ReviewRequestState.merged, true), (.closed, false)])
    func readinessAllowsAMergedEntryBelowButNotAClosedOne(below: ReviewRequestState, ready: Bool) {
        let requests = [Self.request(41, state: below), Self.request(42)]
        var record = Self.record([41, 42])
        // The head gate needs a head seen on consecutive polls.
        record = StackShepherdPolicy.decide(record, Self.observation(requests, now: F.earlier)).record

        let decision = StackShepherdPolicy.decide(record, Self.observation(requests))

        #expect(decision.gatePasses == ready)
        #expect(decision.notifyReady == ready)
    }

    /// A closed entry the user removed from the stack is gone, not a closed
    /// stack: it must not keep the entries that remain from being ready.
    @Test func aClosedEntryRemovedFromTheStackIsDropped() {
        let requests = [Self.request(41, state: .closed), Self.request(42)]
        var record = Self.record([41, 42])

        // Closed and removed in one poll: dropped without a closed notice.
        let once = StackShepherdPolicy.decide(record, Self.observation(requests, present: ["c-42"], now: F.earlier))
        #expect(once.record.entries.map(\.requestNumber) == [42])
        #expect(once.entryEvents.isEmpty)

        // Closed while still listed, removed on a later poll.
        record = StackShepherdPolicy.decide(record, Self.observation(requests, present: ["c-41", "c-42"], now: F.earlier)).record
        #expect(record.entries.map(\.shepherd.phase).first == .closed)
        record = StackShepherdPolicy.decide(record, Self.observation(requests, present: ["c-42"])).record
        #expect(record.entries.map(\.requestNumber) == [42])

        let ready = StackShepherdPolicy.decide(record, Self.observation(requests, present: ["c-42"]))
        #expect(ready.gatePasses)
    }

    /// After the bottom lands, gg still lists its commit until the stack is
    /// rebased: the owner is asked once to restack with stack_ship, and the
    /// rest is not ready to land until gg drops the landed commit.
    @Test func aLandingGGStillListsAsksTheOwnerOnceToRestack() {
        let requests = [Self.request(41, state: .merged), Self.request(42)]
        // `gg land` forgot #41, so only #42 is published.
        let landed = StackShepherdPolicy.decide(
            Self.record([41, 42]),
            Self.observation(requests, present: ["c-42"], listed: ["c-41", "c-42"], now: F.earlier)
        )
        #expect(landed.record.entries[0].shepherd.phase == .merged)
        #expect(landed.restack.map(\.entryID) == ["c-41"])

        let again = StackShepherdPolicy.decide(landed.record, Self.observation(requests, present: ["c-42"], listed: ["c-41", "c-42"]))
        #expect(again.restack.isEmpty)
        #expect(!again.gatePasses)

        let rebased = StackShepherdPolicy.decide(again.record, Self.observation(requests, present: ["c-42"], listed: ["c-42"]))
        #expect(rebased.record.landedEntryIDs == nil && rebased.record.restackRequestedFor == nil)
        #expect(rebased.gatePasses)
    }

    /// An upper entry merged into the entry below it has not reached the
    /// base: a rebase would keep it, so it must not ask for one, or every
    /// stack_ship would rebase again.
    @Test func anEntryMergedIntoItsParentIsNotLanded() {
        let requests = [Self.request(41), Self.request(42, state: .merged, base: "nacho/auth--c-41")]

        let decision = StackShepherdPolicy.decide(Self.record([41, 42]), Self.observation(requests, listed: ["c-41", "c-42"]))

        #expect(decision.record.entries[1].shepherd.phase == .merged)
        #expect(decision.restack.isEmpty && decision.record.landedEntryIDs == nil)
        #expect(StackShepherdPolicy.landedEntryIDs(of: decision.record, in: Self.stack([41, 42])).isEmpty)
    }

    private static func stack(published: [Bool], synced: Int? = nil) -> GGStack {
        GGStack(
            name: "auth", base: "main", totalCommits: published.count, syncedCommits: synced ?? published.count,
            currentPosition: published.count, behindBase: 0,
            entries: published.enumerated().map { index, isPublished in
                GGStackEntry(position: index + 1, sha: "sha\(index)", title: "t", prNumber: isPublished ? 40 + index : nil)
            }
        )
    }

    private static func dirty(staged: Bool = false) -> ReviewLoopLocalState {
        ReviewLoopLocalState(
            branchName: "nacho/auth", headSHA: F.head, baseBranch: "main",
            hasWorkingTreeChanges: !staged, hasStagedChanges: staged, aheadCommitCount: 2,
            hasUpstream: true, upstreamRemoteName: "origin", upstreamBranchName: "nacho/auth",
            needsPush: false
        )
    }

    /// Green requests describe the stack only when gg lists every entry
    /// published and synced and the worktree holds no edits; uncommitted work
    /// counts like an unpublished commit, as in a single PR's merge gate.
    @Test func publicationRequiresEveryEntryPublishedSyncedAndNoEdits() {
        let clean = Self.local
        let all = StackShepherdPolicy.publication(of: Self.stack(published: [true, true]), local: clean)
        #expect(all.isPublished && all.hasUnpublishedEntries == false)

        let newCommit = StackShepherdPolicy.publication(of: Self.stack(published: [true, false]), local: clean)
        #expect(!newCommit.isPublished && newCommit.hasUnpublishedEntries == true)

        let rewritten = StackShepherdPolicy.publication(of: Self.stack(published: [true, true], synced: 1), local: clean)
        #expect(!rewritten.isPublished && rewritten.hasUnpublishedEntries == false)

        for local in [Self.dirty(), Self.dirty(staged: true)] {
            let edited = StackShepherdPolicy.publication(of: Self.stack(published: [true, true]), local: local)
            #expect(!edited.isPublished && edited.hasUnpublishedEntries == true)
        }

        // `gg land` forgets a landed entry's request: until a rebase drops
        // it, it is neither unpublished work nor part of a published stack.
        let landed = StackShepherdPolicy.publication(of: Self.stack(published: [false, true], synced: 1), local: clean, landed: ["sha0"])
        #expect(!landed.isPublished && landed.hasUnpublishedEntries == false)

        // On another stack nothing is known about this one: not ready, and no
        // verdict on unpublished work, so a stack last seen with an
        // unpublished entry cannot be announced from a clean stack B.
        let away = StackShepherdPolicy.publication(of: nil, local: clean)
        #expect(!away.isPublished && away.hasUnpublishedEntries == nil)
        #expect(!StackShepherdPolicy.publication(of: nil, local: Self.dirty()).isPublished)
    }

    /// `pr_status` reports the stack as gg lists it now, not the record as of
    /// the last poll: a commit published with gg sync since is in it, one
    /// removed is out of it, and the order is gg's.
    @Test func statusEntriesFollowTheStackGGListsNow() {
        var record = Self.record([41, 42])
        record.entries[1].shepherd.fixAttempts = 2

        // 42 removed, 43 published, and a local commit not published yet.
        let changed = GGStack(
            name: "auth", base: "main", totalCommits: 3, syncedCommits: 2, currentPosition: 3, behindBase: 0,
            entries: [
                GGStackEntry(position: 1, sha: "a", title: "Entry 41", ggId: "c-41", prNumber: 41),
                GGStackEntry(position: 2, sha: "b", title: "Entry 43", ggId: "c-43", prNumber: 43),
                GGStackEntry(position: 3, sha: "c", title: "Local", ggId: "c-99", prNumber: nil),
            ]
        )
        let rows = StackShepherdPolicy.statusEntries(of: record, stack: changed, now: F.now)

        #expect(rows.map(\.entryID) == ["c-41", "c-43", "c-99"])
        #expect(rows.map(\.requestNumber) == [41, 43, nil])
        #expect(rows[0].shepherd?.fixAttempts == 0)
        #expect(rows[1].shepherd?.phase == .watching)
        #expect(rows[2].shepherd == nil)

        // The record's state follows an entry that kept its request.
        let unchanged = StackShepherdPolicy.statusEntries(of: record, stack: Self.stack([41, 42]), now: F.now)
        #expect(unchanged[1].shepherd?.fixAttempts == 2)

        // No stack, or another one checked out: the record as of the last poll.
        let asRecorded = StackShepherdPolicy.statusEntries(of: record, stack: nil, now: F.now)
        #expect(asRecorded.map(\.requestNumber) == [41, 42])
        let other = GGStack(name: "other", base: "main", totalCommits: 0, syncedCommits: 0, currentPosition: nil, behindBase: nil, entries: [])
        #expect(StackShepherdPolicy.statusEntries(of: record, stack: other, now: F.now).map(\.requestNumber) == [41, 42])
    }

    /// A request closed and then reopened is a live entry again; left closed
    /// it would block the ready gate until the user stopped and restarted.
    @Test func aReopenedEntryIsWatchedAgain() {
        var record = Self.record([41, 42])
        record = StackShepherdPolicy.decide(record, Self.observation(
            [Self.request(41, state: .closed), Self.request(42)], now: F.earlier
        )).record
        #expect(record.entries[0].shepherd.phase == .closed)

        let reopened = StackShepherdPolicy.decide(record, Self.observation([Self.request(41), Self.request(42)]))

        #expect(reopened.record.entries[0].shepherd.phase == .watching)
        #expect(reopened.record.entries[0].shepherd.finishedAt == nil)
        #expect(reopened.record.openEntries.count == 2)

        // Still closed: stays closed, and a merged entry never comes back.
        let still = StackShepherdPolicy.decide(record, Self.observation([Self.request(41, state: .closed), Self.request(42)]))
        #expect(still.record.entries[0].shepherd.phase == .closed)
    }

    @Test func thePollReadsClosedEntriesSoAReopenedOneIsSeen() async throws {
        // Entry 41 closed while 42 stays open, so the record is still live.
        var closed = Self.record([41, 42])
        closed.entries[0].shepherd.phase = .closed
        closed.entries[0].shepherd.finishedAt = F.now
        let fileURL = URL(fileURLWithPath: "/memory/stack-shepherds.json")
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [closed]), to: fileURL)
        let stack = Self.stack([41, 42])
        // Request 41 is open again at the provider.
        let shepherd = makeShepherd(requests: [Self.request(41), Self.request(42)], stack: stack, store: store)
        let id = closed.id
        #expect(shepherd.records[id]?.entries[0].shepherd.phase == .closed)

        await shepherd.evaluateNow(id)

        #expect(shepherd.records[id]?.entries[0].shepherd.phase == .watching)
    }

    @Test(arguments: [
        (true, false, [41], false, StackShipAction.shepherding(stackName: "auth")),
        (false, true, [41], false, .adopt),
        (false, false, [41, 42], false, .adopt),
        (false, false, [41, 0], true, .unavailable("Wait for the current turn to finish.")),
        (false, false, [41, 0], false, .create),
    ] as [(Bool, Bool, [Int], Bool, StackShipAction)])
    func shipActionFollowsTheStackAndItsOwner(
        ownRecord: Bool, otherRecord: Bool, numbers: [Int], isBusy: Bool, expected: StackShipAction
    ) {
        // 0 marks an entry gg has not published yet.
        let stack = GGStack(
            name: "auth", base: "main", totalCommits: numbers.count, syncedCommits: 0,
            currentPosition: numbers.count, behindBase: 0,
            entries: numbers.enumerated().map { index, number in
                GGStackEntry(position: index + 1, sha: "sha\(index)", title: "t", prNumber: number == 0 ? nil : number)
            }
        )
        var other = Self.record([41])
        other.sessionID = "session-2"

        let action = StackShipAction.resolve(
            record: ownRecord ? Self.record([41]) : nil,
            otherRecord: otherRecord ? other : nil,
            stack: stack,
            isBusy: isBusy
        )

        #expect(action == expected)
    }

    /// The pill matches the popover's action: a finished record still opens
    /// the bound view, which has no Ship; adopting a published stack runs
    /// mid-turn; an unknown stack counts as shippable once the turn ends.
    /// `stack` is nil (unknown), "published" or "unpublished".
    @Test(arguments: [
        ("live", nil, false, false),
        ("finished", nil, false, false),
        ("none", nil, false, true),
        ("none", nil, true, false),
        ("none", "published", true, true),
        ("none", "unpublished", true, false),
        ("none", "unpublished", false, true),
        ("other", nil, true, true),
    ] as [(String, String?, Bool, Bool)])
    func stackPillInvitesShipWhenThePopoverActionCanRun(record kind: String, stack: String?, isBusy: Bool, expected: Bool) {
        let live = Self.record([41])
        let finished = StackShepherdPolicy.decide(
            live, Self.observation([Self.request(41, state: .merged)], hasUnpublishedEntries: false)
        ).record
        #expect(finished.isFinished)
        var other = live
        other.sessionID = "session-2"
        let published = Self.stack([41, 42])
        let unpublished = GGStack(
            name: "auth", base: "main", totalCommits: 2, syncedCommits: 1, currentPosition: 2, behindBase: 0,
            entries: [published.entries[0], GGStackEntry(position: 2, sha: "sha42", title: "Entry 42")]
        )

        let invites = StackShipAction.invitesShip(
            record: kind == "live" ? live : kind == "finished" ? finished : nil,
            otherRecord: kind == "other" ? other : nil,
            stack: stack == "published" ? published : stack == "unpublished" ? unpublished : nil,
            isBusy: isBusy
        )

        #expect(invites == expected)
    }

    /// Pins the agent-facing `pr_status` keys for a stack, including the
    /// explicit nulls agents rely on.
    @Test func stackStatusWireKeepsEveryKey() {
        let wire = StackStatusWire(
            stack: .init(name: "auth", base: "main", entries: [
                .init(position: 1, entryId: "c-41", title: "Add store", pullRequest: nil, phase: nil),
            ]),
            shepherd: nil
        )

        #expect(ReviewCommentWireDTO.jsonLine(wire)
            == #"{"shepherd":null,"stack":{"base":"main","entries":[{"entry_id":"c-41","phase":null,"position":1,"pull_request":null,"title":"Add store"}],"name":"auth"}}"#)
    }

    // MARK: Service

    private final class MemoryStore: PersistenceStoreProtocol {
        var files: [URL: Data] = [:]

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            files[url] = try JSONEncoder().encode(value)
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            guard let data = files[url] else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }

    /// Serves requests by number.
    private struct FakeProvider: CodeHostProvider {
        let requests: [Int: ReviewRequest]
        var kind: CodeHostKind { .github }
        var capabilities: CodeHostProviderCapabilities { .githubCLI }

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
        ) async throws -> ReviewRequest? {
            nil
        }
        func reviewRequest(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> ReviewRequest {
            guard let request = requests[number] else { throw CodeHostProviderError.unsupportedProvider(kind) }
            return request
        }
        func createReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
            title: String, body: String, isDraft: Bool, cwd: URL
        ) async throws -> URL {
            throw CodeHostProviderError.unsupportedProvider(kind)
        }
        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
            request.checks
        }
        func rerunFailedChecks(
            remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL
        ) async throws {}
    }

    /// A shepherd of `stack` serving `requests`, with a session that records
    /// every prompt delivered to it.
    private func makeShepherd(
        requests: [ReviewRequest],
        stack: GGStack,
        contextStackName: String? = "auth",
        store: MemoryStore = MemoryStore(),
        deliverPrompt: @escaping @MainActor (String) -> Void = { _ in },
        archive: @escaping @MainActor () -> Void = {}
    ) -> StackShepherd {
        let shepherd = StackShepherd(
            store: store,
            fileURL: URL(fileURLWithPath: "/memory/stack-shepherds.json"),
            providerRegistry: CodeHostProviderRegistry(providers: [
                .github: FakeProvider(requests: Dictionary(uniqueKeysWithValues: requests.map { ($0.number, $0) })),
            ]),
            localProbe: ReviewLoopLocalProbe { _, _ in (local: Self.local, remotes: []) },
            operationInProgress: { _ in false },
            now: { F.now }
        )
        shepherd.effects = StackShepherd.Effects(
            worktreeContext: { worktreeID in
                .init(worktreeID: worktreeID, path: URL(fileURLWithPath: "/tmp/\(worktreeID)"), stackName: contextStackName, isEligible: true)
            },
            loadStack: { _ in stack },
            syncStack: { _ in },
            rebaseStack: { _ in },
            sessionState: { _, _ in .idle },
            deliverPrompt: { _, _, prompt, _ in
                deliverPrompt(prompt.text)
                return .delivered
            },
            rules: { _ in .none },
            notify: { _ in },
            archiveWorktreeIfAllowed: { _, _, _ in
                archive()
                return .declined
            }
        )
        return shepherd
    }

    private func bind(_ shepherd: StackShepherd, session: String, stack: GGStack) async -> StackShepherdRecord {
        await shepherd.bind(
            sessionID: session, worktreeID: "wt-1", stack: stack,
            requests: [:], remote: F.remote(), autoFix: true, maxFixAttempts: 3, contextRules: nil
        )
    }

    /// Archive-after-merge hides the worktree, so it only runs while the
    /// worktree is still on the stack that landed, not on one the user moved to.
    @Test(arguments: [("auth", 1), ("other", 0), (nil, 0)] as [(String?, Int)])
    func landedStackArchivesOnlyWhileTheWorktreeIsStillOnIt(currentStack: String?, archived: Int) async {
        let stack = Self.stack([41])
        var archives = 0
        let shepherd = makeShepherd(
            requests: [Self.request(41, state: .merged)], stack: stack, contextStackName: currentStack
        ) { _ in } archive: { archives += 1 }
        let record = await bind(shepherd, session: "session-1", stack: stack)

        await shepherd.evaluateNow(record.id)

        #expect(shepherd.records[record.id]?.isFinished == true)
        #expect(archives == archived)
    }

    @Test func onePollSendsOneFixTurnForEveryEntryInNeed() async throws {
        let stack = Self.stack([41, 42, 43])
        var delivered: [String] = []
        let shepherd = makeShepherd(
            requests: [
                Self.request(41, threads: [F.trustedThread]),
                Self.request(42),
                Self.request(43, checks: [F.failing]),
            ],
            stack: stack
        ) { delivered.append($0) }
        let record = await bind(shepherd, session: "session-1", stack: stack)

        await shepherd.evaluateNow(record.id)

        let text = try #require(delivered.first)
        #expect(delivered.count == 1)
        let bottom = try #require(text.range(of: "# Entry 1 ·"))
        let top = try #require(text.range(of: "# Entry 3 ·"))
        #expect(bottom.lowerBound < top.lowerBound)
        #expect(!text.contains("# Entry 2 ·"))
    }

    /// The fix prompt tells the agent to publish with `stack_ship`, which binds
    /// again. That must not erase what the shepherd knows about the fix, or an
    /// entry that keeps failing never runs out of attempts.
    @Test func ownerRepublishingKeepsFixStateAndANewOwnerStartsFresh() async {
        let stack = Self.stack([41])
        let shepherd = makeShepherd(requests: [Self.request(41, checks: [F.failing])], stack: stack)
        let record = await bind(shepherd, session: "session-1", stack: stack)
        await shepherd.evaluateNow(record.id)
        let dispatched = shepherd.records[record.id]?.entries[0].shepherd
        #expect(dispatched?.fixAttempts == 1)
        #expect(dispatched?.phase == .fixing(dispatchedAt: F.now))

        let republished = await bind(shepherd, session: "session-1", stack: stack)
        #expect(republished.entries[0].shepherd.fixAttempts == 1)
        #expect(republished.entries[0].shepherd.phase == .fixing(dispatchedAt: F.now))
        #expect(republished.entries[0].shepherd.lastDispatchedFingerprint == dispatched?.lastDispatchedFingerprint)

        let takenOver = await bind(shepherd, session: "session-2", stack: stack)
        #expect(takenOver.entries[0].shepherd.fixAttempts == 0)
        #expect(takenOver.entries[0].shepherd.phase == .watching)
        #expect(takenOver.entries[0].shepherd.lastDispatchedFingerprint == nil)
        #expect(takenOver.entries[0].shepherd.sessionID == "session-2")
    }

    // MARK: Core routing

    private func makeCore(store: MemoryStore = MemoryStore()) -> AlasCoreContext {
        AlasCoreContext(
            projects: ProjectsManager(persistedProjects: []), store: store,
            runHistoryStore: nil, attentionStore: .scratch()
        )
    }

    private func standalone(_ core: AlasCoreContext, number: Int, session: String, worktree: String) async {
        await core.reviewShepherd.bind(
            sessionID: session, worktreeID: worktree, request: Self.request(number), baseBranch: "main",
            autoFix: true, autoMerge: true, contextRules: nil
        )
    }

    /// A request has one shepherd: two would both dispatch fixes for it, and a
    /// standalone record with auto-merge on could merge one entry of a stack.
    @Test func aRequestHasOneShepherdWhicheverKindBindsLast() async {
        let core = makeCore()
        await standalone(core, number: 41, session: "other", worktree: "wt-1")
        await standalone(core, number: 99, session: "other-2", worktree: "wt-1")
        await standalone(core, number: 42, session: "other-3", worktree: "wt-2")

        core.releasePRShepherds(forStackBindOf: [41, 42], sessionID: "session-1", worktreeID: "wt-1")

        #expect(Set(core.reviewShepherd.records.keys.map(\.requestNumber)) == [99, 42])

        let stack = Self.stack([41, 42])
        await core.stackShepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", stack: stack,
            requests: [:], remote: F.remote(), autoFix: true, maxFixAttempts: 3, contextRules: nil
        )
        core.releaseStackShepherds(forStandaloneBindOf: Self.request(77), sessionID: "other", worktreeID: "wt-1")
        #expect(core.stackShepherd.records.count == 1)
        core.releaseStackShepherds(forStandaloneBindOf: Self.request(42), sessionID: "other", worktreeID: "wt-2")
        #expect(core.stackShepherd.records.count == 1)
        core.releaseStackShepherds(forStandaloneBindOf: Self.request(42), sessionID: "other", worktreeID: "wt-1")
        #expect(core.stackShepherd.records.isEmpty)
    }

    /// A closed entry kept beside live ones comes back under whatever owner and
    /// settings the stack has when its request reopens, not the previous bind's.
    @Test func aRetainedClosedEntryTakesTheNewOwnersSettings() async throws {
        var seeded = Self.record([41, 42])
        seeded.entries[0].shepherd.phase = .closed
        seeded.entries[0].shepherd.finishedAt = F.now
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [seeded]), to: URL(fileURLWithPath: "/memory/stack-shepherds.json"))
        let shepherd = makeShepherd(requests: [], stack: Self.stack([41, 42]), store: store)

        let rebound = await shepherd.bind(
            sessionID: "session-2", worktreeID: "wt-1", stack: Self.stack([41, 42]),
            requests: [:], remote: F.remote(), autoFix: false, maxFixAttempts: 5, contextRules: nil
        )

        let closed = rebound.entries[0].shepherd
        #expect(closed.phase == .closed)
        #expect(closed.sessionID == "session-2")
        #expect(!closed.autoFix)
        #expect(closed.maxFixAttempts == 5)
        #expect(rebound.entries[1].shepherd.phase == .watching)
    }

    /// A locally closed entry whose request just reopened is still a stack
    /// entry: a standalone bind of it must release the stack, or the next poll
    /// reactivates it beside the standalone shepherd.
    @Test func aStandaloneBindReleasesAStackHoldingTheRequestClosed() async throws {
        var seeded = Self.record([41, 42])
        seeded.entries[0].shepherd.phase = .closed
        seeded.entries[0].shepherd.finishedAt = F.now
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [seeded]), to: Paths.stackShepherdsFile)
        let core = makeCore(store: store)

        core.releaseStackShepherds(forStandaloneBindOf: Self.request(41), sessionID: "other", worktreeID: "wt-1")

        #expect(core.stackShepherd.records.isEmpty)
    }

    /// A finished record stays listed after its worktree moves on; it must not
    /// route `pr_status` into the stack path, which refuses a non-stack worktree.
    @Test func prStatusIgnoresAFinishedStackRecordInAWorktreeOffTheStack() async throws {
        var finished = Self.record([41])
        finished.entries[0].shepherd.phase = .merged
        finished.finishedAt = Date()
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [finished]), to: Paths.stackShepherdsFile)
        let core = makeCore(store: store)
        #expect(core.stackShepherd.record(forSession: "session-1")?.isFinished == true)
        core.stackShepherd.effects = StackShepherd.Effects(
            worktreeContext: { .init(worktreeID: $0, path: URL(fileURLWithPath: "/tmp/\($0)"), stackName: nil, isEligible: true) },
            loadStack: { _ in nil },
            syncStack: { _ in },
            rebaseStack: { _ in },
            sessionState: { _, _ in .idle },
            deliverPrompt: { _, _, _, _ in .delivered },
            rules: { _ in .none },
            notify: { _ in },
            archiveWorktreeIfAllowed: { _, _, _ in .declined }
        )

        let status = try await core.shepherdedStackStatus(sessionID: "session-1", worktreeID: "wt-1")

        #expect(status == nil)
    }

    /// A worktree can hold records for several stacks; only the one it is on
    /// can be taken over from there.
    @Test func aTakeoverTargetIsTheLiveRecordOfTheStackTheWorktreeIsOn() throws {
        var onB = Self.record([51])
        onB = StackShepherdRecord(
            id: StackShepherdRecordID(worktreeID: "wt-1", stackName: "b"), sessionID: "session-3",
            remote: F.remote(), base: "main", autoFix: true, entries: onB.entries, now: F.earlier
        )
        var finishedB = onB
        finishedB.entries[0].shepherd.phase = .merged
        finishedB.finishedAt = Date()
        let onA = Self.record([41])
        let fileURL = URL(fileURLWithPath: "/memory/stack-shepherds.json")
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [onA, onB]), to: fileURL)
        let shepherd = StackShepherd(store: store, fileURL: fileURL)

        #expect(shepherd.liveRecord(forWorktree: "wt-1", stackName: "auth")?.sessionID == "session-1")
        #expect(shepherd.liveRecord(forWorktree: "wt-1", stackName: "b")?.sessionID == "session-3")
        #expect(shepherd.liveRecord(forWorktree: "wt-1", stackName: "c") == nil)
        #expect(shepherd.liveRecord(forWorktree: "wt-2", stackName: "auth") == nil)

        let finishedStore = MemoryStore()
        try finishedStore.write(StackShepherdsFile(records: [finishedB]), to: fileURL)
        #expect(StackShepherd(store: finishedStore, fileURL: fileURL).liveRecord(forWorktree: "wt-1", stackName: "b") == nil)
    }

    /// `pr_status` reads fresh requests, so it must not report the cached
    /// gate from the last poll: a republish or a rerun changes heads and
    /// checks in between.
    @Test func readyToLandIsRevalidatedAgainstFreshRequests() async {
        let green = [Self.request(41), Self.request(42)]
        let stack = Self.stack([41, 42])
        let shepherd = makeShepherd(requests: green, stack: stack)
        let record = await bind(shepherd, session: "session-1", stack: stack)
        // The head gate needs a head seen on consecutive polls.
        await shepherd.evaluateNow(record.id)
        await shepherd.evaluateNow(record.id)
        let fresh = Dictionary(uniqueKeysWithValues: green.map { ($0.number, $0) })
        #expect(shepherd.gatePasses[record.id] == true)
        func ready(
            _ requests: [Int: ReviewRequest], stack: GGStack? = Self.stack([41, 42]),
            reviewers: [Int: Set<String>] = [:], rules: ShepherdRules = .none
        ) async -> Bool {
            await shepherd.isReadyToLand(
                record.id, freshRequests: requests, stack: stack, headReviewers: reviewers, rules: rules
            )
        }
        #expect(await ready(fresh))

        var republished = fresh
        republished[42] = Self.request(42, head: F.newHead)
        #expect(await !ready(republished))

        var failing = fresh
        failing[41] = Self.request(41, checks: [F.failing])
        #expect(await !ready(failing))

        var missing = fresh
        missing[42] = nil
        #expect(await !ready(missing))

        // The stack changed since the poll: a commit gg has not published or
        // synced, with the requests untouched.
        #expect(await !ready(fresh, stack: Self.stack(published: [true, true, false])))
        #expect(await !ready(fresh, stack: Self.stack(published: [true, true], synced: 1)))

        // Nothing known about this stack: the load failed, or the worktree is
        // on another stack that happens to be clean and synced.
        #expect(await !ready(fresh, stack: nil))
        let other = GGStack(
            name: "other", base: "main", totalCommits: 1, syncedCommits: 1, currentPosition: 1, behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "x", title: "t", prNumber: 77)]
        )
        #expect(await !ready(fresh, stack: other))

        // An entry published since the last poll is in the stack but unseen by
        // the shepherd: green on its request is not enough to call it ready.
        var grown = fresh
        grown[43] = Self.request(43)
        #expect(await !ready(grown, stack: Self.stack([41, 42, 43])))
        // One removed since the poll no longer holds the stack back.
        #expect(await ready(fresh, stack: Self.stack([41, 42])))
        var shrunk = fresh
        shrunk[42] = nil
        #expect(await ready(shrunk, stack: Self.stack([41])))

        // A required reviewer that no longer covers the head, with no head change.
        let required = ShepherdRules(source: .projectSettings, instructions: "", requiredReviewers: ["codex"])
        #expect(await !ready(fresh, reviewers: [41: ["codex"], 42: []], rules: required))
        #expect(await ready(fresh, reviewers: [41: ["codex"], 42: ["codex"]], rules: required))
    }

    /// When the last entry is dropped or unstacked and gg lists nothing left
    /// to publish, the record has no stack to watch: it is removed, or it
    /// would stay bound and make stack_ship refuse the next stack.
    @Test(arguments: [(false as Bool?, true), (true as Bool?, false), (nil as Bool?, false)])
    func aRecordWithNoEntriesLeftIsRetiredOnlyWhenNothingUnpublishedRemains(unpublished: Bool?, retired: Bool) {
        let decision = StackShepherdPolicy.decide(
            Self.record([41]), Self.observation([Self.request(41)], present: [], hasUnpublishedEntries: unpublished)
        )

        #expect(decision.record.entries.isEmpty)
        #expect(decision.isRetired == retired)
    }

    @Test func theServiceRemovesARecordWhoseStackWasEmptied() async {
        let emptied = Self.stack([])
        let shepherd = makeShepherd(requests: [Self.request(41)], stack: emptied)
        let record = await bind(shepherd, session: "session-1", stack: Self.stack([41]))
        #expect(shepherd.records[record.id] != nil)

        await shepherd.evaluateNow(record.id)

        #expect(shepherd.records[record.id] == nil)
    }

    /// A late fix turn for stack A must not publish stack B, which would drop
    /// the record for A: the session stops shepherding A first, or goes back.
    @Test func stackShipRefusesAWorktreeOnAnotherStackThanTheOneTheSessionShepherds() async throws {
        let store = MemoryStore()
        try store.write(StackShepherdsFile(records: [Self.record([41])]), to: Paths.stackShepherdsFile)
        let core = makeCore(store: store)
        var synced = 0
        let otherStack = GGStack(
            name: "b", base: "main", totalCommits: 1, syncedCommits: 0, currentPosition: 1, behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "x", title: "t", prNumber: nil)]
        )
        core.stackShepherd.effects = StackShepherd.Effects(
            worktreeContext: { .init(worktreeID: $0, path: URL(fileURLWithPath: "/tmp/\($0)"), stackName: "b", isEligible: true) },
            loadStack: { _ in otherStack },
            syncStack: { _ in synced += 1 },
            rebaseStack: { _ in },
            sessionState: { _, _ in .idle },
            deliverPrompt: { _, _, _, _ in .delivered },
            rules: { _ in .none },
            notify: { _ in },
            archiveWorktreeIfAllowed: { _, _, _ in .declined }
        )

        let response = await core.shipStack(sessionID: "session-1", worktreeID: "wt-1")

        guard case .error(let message) = response else {
            Issue.record("expected a refusal, got \(response)")
            return
        }
        #expect(message.contains("shepherds the gg stack \"auth\""))
        #expect(synced == 0)
        #expect(core.stackShepherd.record(forSession: "session-1")?.id.stackName == "auth")
    }
}
