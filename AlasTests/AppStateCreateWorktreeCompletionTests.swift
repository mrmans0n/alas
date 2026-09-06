import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Worktree creation completion")
struct AppStateCreateWorktreeCompletionTests {
    private static let worktree = Worktree(
        id: "worktree",
        projectId: "project",
        name: "feature",
        branch: "feature",
        path: URL(fileURLWithPath: "/tmp/worktree"),
        status: .clean,
        lastActivity: Date(timeIntervalSince1970: 0)
    )

    @Test
    func waiterReturnsOnlyAfterReconciledWorktreeExists() async {
        var states: [WorktreeOperationState?] = [.creating, nil, nil]
        var worktrees: [Worktree?] = [nil, nil, Self.worktree]

        let result = await WorktreeCreationCompletion.wait(
            id: Self.worktree.id,
            maxPolls: 3,
            operationState: { states.removeFirst() },
            worktree: { worktrees.removeFirst() },
            sleep: {}
        )

        #expect(result == .success(Self.worktree))
    }

    @Test
    func waiterPreservesCreateFailureMessage() async {
        let result = await WorktreeCreationCompletion.wait(
            id: "pending",
            maxPolls: 1,
            operationState: {
                .createFailed(
                    projectId: "project",
                    message: "branch exists",
                    base: "main",
                    ggWorktreeMode: .inherit,
                    launchSurface: .none,
                    issueAttachment: nil
                )
            },
            worktree: { nil },
            sleep: {}
        )

        #expect(result == .failure(.init(message: "branch exists")))
    }

    @Test
    func waiterReconcilesAWorktreeCreatedBeforeRefreshFailed() async {
        var state: WorktreeOperationState? = .createFailed(
            projectId: "project",
            message: "connection lost",
            base: "main",
            ggWorktreeMode: .inherit,
            launchSurface: .none,
            issueAttachment: nil
        )
        var reconciled: Worktree?

        let result = await WorktreeCreationCompletion.wait(
            id: Self.worktree.id,
            maxPolls: 1,
            operationState: { state },
            worktree: { reconciled },
            reconcile: {
                reconciled = Self.worktree
                state = nil
            },
            sleep: {}
        )

        #expect(result == .success(Self.worktree))
    }

    @Test
    func waiterRetriesWhenTheOptimisticRowIsTemporarilyMissing() async {
        var states: [WorktreeOperationState?] = [nil, nil]
        var worktrees: [Worktree?] = [nil, Self.worktree]

        let result = await WorktreeCreationCompletion.wait(
            id: Self.worktree.id,
            maxPolls: 2,
            operationState: { states.removeFirst() },
            worktree: { worktrees.removeFirst() },
            sleep: {}
        )

        #expect(result == .success(Self.worktree))
    }

    @Test
    func waiterReportsDeletionAsAnInterruptedCreation() async {
        let result = await WorktreeCreationCompletion.wait(
            id: "pending",
            maxPolls: 1,
            operationState: { .deleting },
            worktree: { Self.worktree },
            sleep: {}
        )

        #expect(result == .failure(.init(message: "Worktree creation was interrupted.")))
    }

    @Test
    func waiterTimesOutAfterThePollLimit() async {
        var sleeps = 0

        let result = await WorktreeCreationCompletion.wait(
            id: "pending",
            maxPolls: 2,
            operationState: { nil },
            worktree: { nil },
            sleep: { sleeps += 1 }
        )

        #expect(result == .failure(.init(message: "Timed out waiting for worktree creation.")))
        #expect(sleeps == 2)
    }

    @Test
    func waiterDoesNotTimeOutWhileCreationRemainsActive() async {
        var states: [WorktreeOperationState?] = [.creating, .creating, nil]
        var worktrees: [Worktree?] = [nil, nil, Self.worktree]

        let result = await WorktreeCreationCompletion.wait(
            id: Self.worktree.id,
            maxPolls: 1,
            operationState: { states.removeFirst() },
            worktree: { worktrees.removeFirst() },
            sleep: {}
        )

        #expect(result == .success(Self.worktree))
    }

    @Test
    func waiterStopsPollingWhenItsCallerIsCancelled() async {
        let outcome = WorktreeCreationWaitOutcome()
        let gate = WorktreeCreationPollGate(outcome: outcome)
        var state: WorktreeOperationState? = .creating
        let task = Task { @MainActor in
            let result = await WorktreeCreationCompletion.wait(
                id: "pending",
                maxPolls: 1,
                operationState: { state },
                worktree: { nil },
                sleep: { await gate.wait() }
            )
            let interrupted = result == .failure(.init(message: "Worktree creation was interrupted."))
            await outcome.recordCompletion(interrupted: interrupted)
            return interrupted
        }

        guard await gate.waitForFirstEntry() else {
            Issue.record("waiter did not enter its first poll")
            task.cancel()
            await gate.releaseAll()
            _ = await task.value
            return
        }
        task.cancel()
        await gate.releaseOne()

        let event = await outcome.waitForEvent()

        // Let the pre-fix waiter leave its second poll rather than leaking it
        // when this assertion demonstrates that it ignored cancellation.
        state = nil
        await gate.releaseAll()

        switch event {
        case .secondPoll:
            Issue.record("cancelled waiter started a second poll")
        case .completed(let interrupted):
            #expect(interrupted)
        case .timedOut:
            Issue.record("cancelled waiter did not complete")
        }
        #expect(await task.value)
    }
}

private actor WorktreeCreationPollGate {
    private static let timeoutNanoseconds: UInt64 = 1_000_000_000
    private let outcome: WorktreeCreationWaitOutcome
    private var entries = 0
    private var isOpen = false
    private var firstEntryContinuation: CheckedContinuation<Bool, Never>?
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(outcome: WorktreeCreationWaitOutcome) {
        self.outcome = outcome
    }

    func wait() async {
        entries += 1
        if entries == 1 {
            firstEntryContinuation?.resume(returning: true)
            firstEntryContinuation = nil
        } else if entries == 2 {
            await outcome.recordSecondPoll()
        }
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForFirstEntry() async -> Bool {
        guard entries == 0 else { return true }
        return await withCheckedContinuation { continuation in
            firstEntryContinuation = continuation
            Task {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                firstEntryContinuation?.resume(returning: false)
                firstEntryContinuation = nil
            }
        }
    }

    func releaseOne() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func releaseAll() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor WorktreeCreationWaitOutcome {
    enum Event {
        case secondPoll
        case completed(interrupted: Bool)
        case timedOut
    }

    private static let timeoutNanoseconds: UInt64 = 1_000_000_000
    private var event: Event?
    private var continuation: CheckedContinuation<Event, Never>?

    func recordSecondPoll() {
        record(.secondPoll)
    }

    func recordCompletion(interrupted: Bool) {
        record(.completed(interrupted: interrupted))
    }

    func waitForEvent() async -> Event {
        if let event { return event }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task {
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                record(.timedOut)
            }
        }
    }

    private func record(_ event: Event) {
        guard self.event == nil else { return }
        self.event = event
        continuation?.resume(returning: event)
        continuation = nil
    }
}
