import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

private typealias F = ShepherdFixtures

@MainActor
struct ReviewShepherdTests {
    @Test("a service started during a fix does not keep Ship busy", arguments: [nil, "shell", "service"] as [String?])
    func backgroundServiceDoesNotBlockShip(taskType: String?) {
        let session = ACPSession(id: "session-1", agentId: "claude", worktreeId: "wt-1", title: "Fix")
        session.agentState = .ready
        session.settlesAtResult = true
        var service = ACPBackgroundTask(ownerSessionId: session.id, asyncTaskId: "preview", name: "Preview server")
        service.taskType = taskType
        service.startedAt = F.now.addingTimeInterval(1)
        session.saveBackgroundTask(service)
        #expect(!AlasCoreContext.shepherdSessionIsBusy(session, now: F.now))
    }

    @Test("autonomous turns and live children keep Ship busy", arguments: [
        // Ready adapter, settles at result, work kind, state, expected busy.
        (true, true, "turn", "running", true),
        (true, true, "turn", "completed", false),
        (true, true, "turn", "lost", false),
        (false, true, "turn", "running", false),
        (true, false, "turn", "running", false),
        (true, false, "child", "running", true),
        (true, false, "child", "requires_action", true),
        (true, false, "child", "completed", false),
    ])
    func backgroundFixActivity(ready: Bool, settles: Bool, kind: String, state: String, expected: Bool) {
        let session = ACPSession(id: "session-1", agentId: "claude", worktreeId: "wt-1", title: "Fix")
        session.agentState = ready ? .ready : .disconnected
        session.settlesAtResult = settles
        if kind == "child" {
            session.registerSubagent(.init(subagentSessionId: "child"))
            if state == "completed" {
                session.applySubagentState(.init(subagentSessionId: "child", state: .completed))
            } else if state == "requires_action" {
                session.applySubagentState(.init(subagentSessionId: "child", state: .requiresAction))
            }
        } else {
            var task = ACPBackgroundTask(ownerSessionId: session.id, asyncTaskId: "cycle", name: "Run tests")
            task.taskType = kind
            task.state = state
            session.saveBackgroundTask(task)
        }
        #expect(AlasCoreContext.shepherdSessionIsBusy(session, now: F.now) == expected)
    }

    @Test func backgroundWorkStartsTheIdleGraceOnlyAfterItFinishes() {
        let snapshot = F.snapshot(F.request(threads: [F.trustedThread]))
        var record = F.record(phase: .awaitingPush(turnEndedAt: F.earlier, pollsWithoutProgress: 2),
                              fixAttempts: 1, lastDispatched: F.fingerprint(
                                ShepherdFixRequest(hasConflict: false, failingChecks: [], threads: [F.trustedThread])))
        record = ShepherdPolicy.decide(record, F.observation(snapshot, session: .busy)).record
        let idle = ShepherdPolicy.decide(record, F.observation(snapshot, now: F.now.addingTimeInterval(3600)))
        #expect(idle.action == .wait)
        #expect(idle.record.phase == .awaitingPush(turnEndedAt: F.now.addingTimeInterval(3600), pollsWithoutProgress: 0))
    }

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

    /// Serves one open request on the worktree's branch.
    private struct FakeProvider: CodeHostProvider {
        let request: ReviewRequest
        var kind: CodeHostKind { .github }

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
        ) async throws -> ReviewRequest? {
            request
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

    /// Holds a prompt delivery until the test releases it.
    private final class DeliveryGate {
        var release: CheckedContinuation<Void, Never>?
        var delivered: [String] = []
    }

    private struct RulesUnreadable: Error {}

    /// A shepherd watching `request`, a branch pushed at its head, owned by an
    /// idle session.
    private func makeShepherd(
        request: ReviewRequest,
        store: MemoryStore = MemoryStore(),
        deliverPrompt: @escaping @MainActor (String, @escaping @MainActor () -> Bool) async -> ReviewShepherd.Delivery,
        rules: @escaping @MainActor () throws -> ShepherdRules = { .none },
        servesWorktree: @escaping @MainActor (String) -> Bool = { _ in true },
        now: @escaping @MainActor () -> Date = { F.now }
    ) -> ReviewShepherd {
        let local = ReviewLoopLocalState(
            branchName: "fix-login", headSHA: F.head, baseBranch: "main",
            hasWorkingTreeChanges: false, hasStagedChanges: false, aheadCommitCount: 1,
            hasUpstream: true, upstreamRemoteName: "origin", upstreamBranchName: "fix-login",
            needsPush: false
        )
        let shepherd = ReviewShepherd(
            store: store,
            fileURL: URL(fileURLWithPath: "/memory/review-shepherds.json"),
            providerRegistry: CodeHostProviderRegistry(providers: [.github: FakeProvider(request: request)]),
            localProbe: ReviewLoopLocalProbe { _, _ in
                (local: local, remotes: [GitRemote(name: "origin", url: "https://github.com/acme/app.git")])
            },
            now: now
        )
        shepherd.effects = ReviewShepherd.Effects(
            worktreeContext: { worktreeID in
                ReviewShepherd.WorktreeContext(
                    worktreeID: worktreeID, projectID: "project-1",
                    path: URL(fileURLWithPath: "/tmp/\(worktreeID)"), baseBranch: "main", isEligible: true
                )
            },
            sessionState: { _, _ in .idle },
            deliverPrompt: { _, _, prompt, isStillWanted in await deliverPrompt(prompt.text, isStillWanted) },
            rules: { _ in try rules() },
            notify: { _ in },
            refreshPaneIfCached: { _ in },
            archiveWorktreeIfAllowed: { _, _, _ in .declined },
            servesWorktree: servesWorktree
        )
        return shepherd
    }

    @Test func aRecordInAWorktreeNotServedHereIsLeftAlone() async {
        let request = F.request(threads: [F.trustedThread])
        var delivered: [String] = []
        let shepherd = makeShepherd(request: request, deliverPrompt: { text, _ in
            delivered.append(text)
            return .delivered
        }, servesWorktree: { _ in false })
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: true, contextRules: nil
        )

        await shepherd.evaluateNow(record.id)

        #expect(shepherd.records[record.id] == record)
        #expect(delivered.isEmpty)
    }

    @Test func bindingTheSessionElsewhereKeepsItsRecordInAWorktreeNotServedHere() async {
        let request = F.request(threads: [])
        let shepherd = makeShepherd(request: request, deliverPrompt: { _, _ in .delivered }, servesWorktree: { $0 != "wt-app" })
        let unserved = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-app", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        #expect(shepherd.records[unserved.id] == unserved)
    }

    @Test func onlyTheBoundSessionCarriesAShepherdPill() async {
        let request = F.request(threads: [])
        let shepherd = makeShepherd(request: request, deliverPrompt: { _, _ in .delivered })
        let stack = StackShepherd(store: MemoryStore(), fileURL: URL(fileURLWithPath: "/memory/stack-shepherds.json"))
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        let pill = HostSessionShepherd.make(sessionID: "session-1", review: shepherd, stack: stack)
        let expected = ShepherdPresentation.make(record: record, request: nil, mergeGatePasses: false)
        #expect(pill?.number == expected.number)
        #expect(pill?.badge == expected.badge.rawValue)
        #expect(HostSessionShepherd.make(sessionID: "session-2", review: shepherd, stack: stack) == nil)
    }

    @Test(arguments: [
        (HostSessionShepherd(badge: "fixing", number: "#7", tooltip: "t"), ShepherdBadgeState.fixing),
        (HostSessionShepherd(badge: "fromANewerHost", number: "#7", tooltip: "t"), nil),
    ] as [(HostSessionShepherd, ShepherdBadgeState?)])
    func peerShowsAPillOnlyForAKnownBadge(shepherd: HostSessionShepherd, badge: ShepherdBadgeState?) {
        #expect(shepherd.badgeState == badge)
    }

    @Test func turnEndingWhileTheFixPromptIsDeliveredKeepsTheFix() async throws {
        let request = F.request(threads: [F.trustedThread])
        let gate = DeliveryGate()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let shepherd = makeShepherd(request: request) { text, isStillWanted in
            await withCheckedContinuation { continuation in
                gate.release = continuation
                enteredContinuation.yield()
            }
            guard isStillWanted() else { return .superseded }
            gate.delivered.append(text)
            return .delivered
        }
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        let evaluation = Task { await shepherd.evaluateNow(record.id) }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        // Another turn of the owner ends while the fix prompt is on its way.
        shepherd.turnCompleted(sessionID: "session-1")
        gate.release?.resume()
        await evaluation.value

        #expect(gate.delivered.count == 1)
        #expect(shepherd.records[record.id]?.phase == .fixing(dispatchedAt: F.now))
    }

    @Test func changingTheFixBudgetWhileTheFixPromptIsDeliveredKeepsTheFix() async throws {
        let request = F.request(threads: [F.trustedThread])
        let gate = DeliveryGate()
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let shepherd = makeShepherd(request: request) { text, isStillWanted in
            await withCheckedContinuation { continuation in
                gate.release = continuation
                enteredContinuation.yield()
            }
            guard isStillWanted() else { return .superseded }
            gate.delivered.append(text)
            return .delivered
        }
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil
        )

        let evaluation = Task { await shepherd.evaluateNow(record.id) }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        shepherd.setMaxFixAttempts(5, for: record.id)
        gate.release?.resume()
        await evaluation.value

        #expect(gate.delivered.count == 1)
        #expect(shepherd.records[record.id]?.phase == .fixing(dispatchedAt: F.now))
        #expect(shepherd.records[record.id]?.fixAttemptBudget == 5)
    }

    @Test func unreadableRulesHoldEveryDecision() async {
        let request = F.request(threads: [F.trustedThread])
        var delivered: [String] = []
        let shepherd = makeShepherd(request: request, deliverPrompt: { text, _ in
            delivered.append(text)
            return .delivered
        }, rules: { throw RulesUnreadable() })
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: true, contextRules: nil
        )

        await shepherd.evaluateNow(record.id)

        #expect(delivered.isEmpty)
        #expect(shepherd.records[record.id]?.phase == .watching)
    }

    @Test func failedDeliveryRetriesAfterRestartWithoutSpendingFixAttempts() async {
        let request = F.request(threads: [F.trustedThread])
        let store = MemoryStore()
        var time = F.now
        var deliveries = 0
        let deliver: @MainActor (String, @escaping @MainActor () -> Bool) async -> ReviewShepherd.Delivery = { _, _ in
            deliveries += 1
            return deliveries < 3 ? .failed : .delivered
        }
        var shepherd = makeShepherd(request: request, store: store, deliverPrompt: deliver, now: { time })
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil)
        for (elapsed, expectedDeliveries) in [(0.0, 1), (29, 1), (30, 2), (89, 2), (90, 3), (91, 3)] {
            time = F.now.addingTimeInterval(elapsed)
            await shepherd.evaluateNow(record.id)
            #expect(deliveries == expectedDeliveries)
            #expect(shepherd.records[record.id]?.fixAttempts == (deliveries < 3 ? 0 : 1))
            #expect(shepherd.records[record.id]?.phase.isResumable == false)
            // Simulate relaunch, including a reload during delivery backoff.
            shepherd = makeShepherd(request: request, store: store, deliverPrompt: deliver, now: { time })
        }
    }

    @Test("a clean PR retries its bind context across restart", arguments: [true, false])
    func cleanPRRetriesBindContext(autoFix: Bool) async throws {
        let request = F.request()
        let store = MemoryStore()
        var time = F.now
        var deliveries = 0
        let deliver: @MainActor (String, @escaping @MainActor () -> Bool) async -> ReviewShepherd.Delivery = { _, _ in
            deliveries += 1
            return deliveries < 3 ? .failed : .delivered
        }
        var shepherd = makeShepherd(request: request, store: store, deliverPrompt: deliver, now: { time })
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: autoFix, autoMerge: false, contextRules: ShepherdRules.none)
        for (elapsed, expectedDeliveries) in [(0.0, 1), (29, 1), (30, 2), (89, 2), (90, 3), (91, 3)] {
            time = F.now.addingTimeInterval(elapsed)
            shepherd = makeShepherd(request: request, store: store, deliverPrompt: deliver, now: { time })
            await shepherd.evaluateNow(record.id)
            #expect(deliveries == expectedDeliveries)
            let current = try #require(shepherd.records[record.id])
            #expect(current.fixAttempts == 0)
            #expect(!current.phase.isResumable)
            if expectedDeliveries == 3 {
                #expect(!ShepherdPresentation.make(record: current, request: request, mergeGatePasses: false).phaseLine.contains("retrying"))
            }
        }
    }

    @Test("pending bind delivery cannot overlap a poll or lose a toggle", arguments: [ReviewShepherd.Delivery.superseded, .failed])
    func bindDeliverySurvivesAToggle(unsent: ReviewShepherd.Delivery) async throws {
        let request = F.request()
        let (entered, signalEntered) = AsyncStream<Void>.makeStream()
        let (released, signalReleased) = AsyncStream<Void>.makeStream()
        var time = F.now
        var attempts = 0
        var accepted = 0
        let shepherd = makeShepherd(request: request, deliverPrompt: { _, wanted in
            attempts += 1
            if attempts == 1 {
                signalEntered.yield()
                var release = released.makeAsyncIterator()
                await release.next()
            }
            guard wanted() else { return unsent }
            accepted += 1
            return .delivered
        }, now: { time })
        let binding = Task {
            await shepherd.bind(sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
                                autoFix: true, autoMerge: false, contextRules: ShepherdRules.none)
        }
        var entry = entered.makeAsyncIterator()
        await entry.next()
        let record = try #require(shepherd.record(forSession: "session-1"))
        await shepherd.evaluateNow(record.id)
        #expect(attempts == 1)
        shepherd.setAutoMerge(true, for: record.id)
        signalReleased.yield()
        _ = await binding.value
        #expect(accepted == 0)
        time = F.now.addingTimeInterval(30)
        await shepherd.evaluateNow(record.id)
        #expect(attempts == 2 && accepted == 1)
        #expect(shepherd.records[record.id]?.autoMerge == true)
        #expect(shepherd.records[record.id]?.pendingBindDelivery == nil)
        #expect(shepherd.records[record.id]?.fixAttempts == 0)
    }

    @Test func republishingKeepsTheSameOwnersFixAllowance() async {
        let request = F.request(threads: [F.trustedThread])
        let shepherd = makeShepherd(request: request) { _, _ in .delivered }
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil)
        await shepherd.evaluateNow(record.id)
        let republished = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil)
        #expect(republished.fixAttempts == 1)
        #expect(republished.phase == .fixing(dispatchedAt: F.now))
        let newOwner = await shepherd.bind(
            sessionID: "session-2", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil)
        #expect(newOwner.fixAttempts == 0)
        #expect(newOwner.phase == .watching)
    }

    @Test(arguments: [ReviewShepherd.Delivery.superseded, .failed])
    func rebindDuringDeliveryDoesNotSpendAnUnsentAttempt(unsent: ReviewShepherd.Delivery) async {
        let request = F.request(threads: [F.trustedThread])
        let (entered, signalEntered) = AsyncStream<Void>.makeStream()
        let (released, signalReleased) = AsyncStream<Void>.makeStream()
        var firstDelivery = true
        var delivered = 0
        let shepherd = makeShepherd(request: request) { _, wanted in
            if firstDelivery {
                firstDelivery = false
                signalEntered.yield()
                var release = released.makeAsyncIterator()
                await release.next()
            }
            guard wanted() else { return unsent }
            delivered += 1
            return .delivered
        }
        let record = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil)
        let evaluation = Task { await shepherd.evaluateNow(record.id) }
        var entry = entered.makeAsyncIterator()
        await entry.next()
        _ = await shepherd.bind(
            sessionID: "session-1", worktreeID: "wt-1", request: request, baseBranch: "main",
            autoFix: true, autoMerge: false, contextRules: nil)
        signalReleased.yield()
        await evaluation.value
        #expect(delivered == 0)
        #expect(shepherd.records[record.id]?.fixAttempts == 0)
        await shepherd.evaluateNow(record.id)
        #expect(delivered == 1)
        #expect(shepherd.records[record.id]?.fixAttempts == 1)
    }
}
