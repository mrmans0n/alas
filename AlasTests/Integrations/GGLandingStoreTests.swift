import Foundation
import Testing
@testable import Alas

private actor LandingTestSuspension {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum GGLandingStoreTestTimeout: Error {
    case timedOut
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw GGLandingStoreTestTimeout.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
struct GGLandingStoreTests {
    private enum TestError: Error {
        case interrupted
    }

    private func seed(projectId: String = "p") -> GGLandingSession.Seed {
        .init(
            projectId: projectId,
            worktreeId: "w",
            stack: "feature",
            base: "main",
            target: "c-2",
            rows: [
                .init(position: 1, title: "One", ggId: "c-1", prNumber: 41),
                .init(position: 2, title: "Two", ggId: "c-2", prNumber: 42),
            ]
        )
    }

    @Test func refusesSecondActiveLandForProject() {
        let store = GGLandingStore()

        #expect(store.begin(seed()))
        #expect(!store.begin(seed()))
        #expect(store.begin(seed(projectId: "other")))
    }

    @Test func cancellationBeforeAttachCancelsRawOperationAndWaitsForCleanup() async {
        let store = GGLandingStore()
        let cleanup = LandingTestSuspension()
        let rawOperation = Task<Void, Error> {
            await cleanup.suspend()
            try Task.checkCancellation()
        }
        let completion = Task<Void, Error> { try await rawOperation.value }
        await cleanup.waitUntilSuspended()
        store.begin(seed())
        store.cancel(projectId: "p")
        #expect(store.sessions["p"]?.phase == .cancelling)

        var cancellationCount = 0
        store.attach(projectId: "p", task: completion) {
            cancellationCount += 1
            rawOperation.cancel()
        }
        #expect(rawOperation.isCancelled)
        #expect(!completion.isCancelled)
        #expect(cancellationCount == 1)
        store.cancel(projectId: "p")
        #expect(cancellationCount == 1)
        #expect(store.sessions["p"]?.phase == .cancelling)
        #expect(!store.begin(seed()))

        await cleanup.release()
        await store.waitForOperation(projectId: "p")
        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["p"]?.error == nil)
        #expect(store.begin(seed()))
    }

    @Test func preflightFailureAfterCancellationFinishesAsCancelled() {
        let store = GGLandingStore()
        store.begin(seed())
        store.cancel(projectId: "p")
        store.fail(projectId: "p", message: "Target no longer exists")
        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["p"]?.error == nil)
        #expect(store.begin(seed()))
    }

    @Test func beginSeedsSessionAndReplacesTerminalAttempt() throws {
        let store = GGLandingStore()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        #expect(store.begin(seed(), now: startedAt))
        let first = try #require(store.sessions["p"])
        #expect(first.worktreeId == "w")
        #expect(first.stack == "feature")
        #expect(first.base == "main")
        #expect(first.target == "c-2")
        #expect(first.startedAt == startedAt)
        #expect(first.phase == .running)

        store.fail(projectId: "p", message: "stopped")
        #expect(store.begin(seed(), now: startedAt.addingTimeInterval(1)))
        let replacement = try #require(store.sessions["p"])
        #expect(replacement.id != first.id)
        #expect(replacement.phase == .running)
        #expect(replacement.error == nil)
    }

    @Test func terminalSessionCannotRestartUntilAttachedOperationFinishes() async {
        let store = GGLandingStore()
        let operation = AsyncStream<Void>.makeStream()
        let task = Task<Void, Error> {
            for await _ in operation.stream {}
        }
        #expect(store.begin(seed()))
        store.attach(projectId: "p", task: task) {
            operation.continuation.finish()
        }
        store.receive(
            .summary(.init(landed: [], error: "partial failure")),
            projectId: "p"
        )

        #expect(!store.begin(seed()))

        operation.continuation.finish()
        await store.cancelAllAndWait()
        #expect(store.begin(seed()))
    }

    @Test func heartbeatUpdatesActiveRowAndClearsRecoveredWarning() {
        let store = GGLandingStore()
        store.begin(seed())
        store.receive(.wait(.init(
            position: 1, prNumber: 41, phase: .readiness, poll: 1,
            elapsedSeconds: 10, ciStatus: "running", approved: true,
            mergeTrainStatus: nil, mergeTrainPosition: nil,
            pipelineRunning: nil, error: "temporary outage"
        )), projectId: "p")
        #expect(store.sessions["p"]?.warning == "temporary outage")
        #expect(store.sessions["p"]?.rows[0].wait?.poll == 1)
        store.receive(.wait(.init(
            position: 1, prNumber: 41, phase: .readiness, poll: 2,
            elapsedSeconds: 20, ciStatus: "success", approved: true,
            mergeTrainStatus: nil, mergeTrainPosition: nil,
            pipelineRunning: nil, error: nil
        )), projectId: "p")
        #expect(store.sessions["p"]?.warning == nil)
        #expect(store.sessions["p"]?.activeWait?.elapsedSeconds == 20)
        #expect(store.sessions["p"]?.rows[0].wait?.poll == 2)
    }

    @Test func entryRecordsTerminalRowAndClearsItsWait() {
        let store = GGLandingStore()
        store.begin(seed())
        store.receive(.wait(.init(
            position: 1, prNumber: 41, phase: .mergeTrain, poll: 3,
            elapsedSeconds: 30, ciStatus: "success", approved: true,
            mergeTrainStatus: "queued", mergeTrainPosition: 2,
            pipelineRunning: false, error: nil
        )), projectId: "p")

        let outcome = GGLandedEntry(
            position: 1, title: "One", ggId: "c-1", prNumber: 41,
            action: "merged"
        )
        store.receive(.entry(outcome), projectId: "p")

        #expect(store.sessions["p"]?.rows[0].outcome == outcome)
        #expect(store.sessions["p"]?.rows[0].wait == nil)
        #expect(store.sessions["p"]?.activeWait == nil)
    }

    @Test func summaryPublishesAuthoritativeRowsAndOutcome() {
        let store = GGLandingStore()
        store.begin(seed())
        let outcome = GGLandedEntry(
            position: 1, title: "One", ggId: "c-1", prNumber: 41,
            action: "merged"
        )
        let result = GGLandResult(
            stack: "feature", base: "main", landed: [outcome],
            remaining: 1, cleaned: false, warnings: ["review skipped"]
        )

        store.receive(.summary(result), projectId: "p")

        #expect(store.sessions["p"]?.phase == .succeeded)
        #expect(store.sessions["p"]?.result == result)
        #expect(store.sessions["p"]?.rows[0].outcome == outcome)
        #expect(store.sessions["p"]?.warning == nil)
        #expect(store.sessions["p"]?.error == nil)
    }

    @Test func summaryErrorAndFatalEventFailSession() {
        let store = GGLandingStore()
        store.begin(seed())
        let result = GGLandResult(landed: [], error: "partial failure")

        store.receive(.summary(result), projectId: "p")
        #expect(store.sessions["p"]?.phase == .failed)
        #expect(store.sessions["p"]?.error == "partial failure")

        #expect(store.begin(seed()))
        store.receive(.error(message: "setup failed"), projectId: "p")
        #expect(store.sessions["p"]?.phase == .failed)
        #expect(store.sessions["p"]?.error == "setup failed")
    }

    @Test func cancelledCompletionWinsOverInterruptedExit() async {
        let store = GGLandingStore()
        store.begin(seed())
        var cancelCount = 0
        let task = Task<Void, Error> { try await Task.sleep(for: .seconds(30)) }
        store.attach(projectId: "p", task: task) {
            cancelCount += 1
            task.cancel()
        }
        store.cancel(projectId: "p")
        store.cancel(projectId: "p")
        await store.cancelAllAndWait()
        #expect(cancelCount == 1)
        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["p"]?.error == nil)
    }

    @Test func unexpectedExitWithoutSummaryFailsSession() async throws {
        let store = GGLandingStore()
        store.begin(seed())
        let task = Task<Void, Error> {}
        store.attach(projectId: "p", task: task) {}

        _ = await task.result
        try await waitUntil { store.sessions["p"]?.phase == .failed }

        #expect(store.sessions["p"]?.phase == .failed)
        #expect(store.sessions["p"]?.error != nil)
    }

    @Test func cancelAllCancelsOnceAndWaitsForMonitors() async {
        let store = GGLandingStore()
        store.begin(seed())
        store.begin(seed(projectId: "other"))
        var cancelCount = 0
        let first = Task<Void, Error> { try await Task.sleep(for: .seconds(30)) }
        let second = Task<Void, Error> { try await Task.sleep(for: .seconds(30)) }
        store.attach(projectId: "p", task: first) {
            cancelCount += 1
            first.cancel()
        }
        store.attach(projectId: "other", task: second) {
            cancelCount += 1
            second.cancel()
        }

        await store.cancelAllAndWait()

        #expect(cancelCount == 2)
        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["other"]?.phase == .cancelled)
    }

    @Test func pruneCancelsRemovedProjectAndRetainsOthers() async {
        let store = GGLandingStore()
        store.begin(seed())
        store.begin(seed(projectId: "other"))
        var cancelCount = 0
        let task = Task<Void, Error> { try await Task.sleep(for: .seconds(30)) }
        store.attach(projectId: "p", task: task) {
            cancelCount += 1
            task.cancel()
        }

        store.prune(keepingProjectIds: ["other"])
        await store.cancelAllAndWait()

        #expect(cancelCount == 1)
        #expect(store.sessions["p"] == nil)
        #expect(store.sessions["other"]?.phase == .running)
    }

    @Test func terminationWaitsForPrunedOperationCleanup() async {
        let store = GGLandingStore()
        let cancellation = AsyncStream<Void>.makeStream()
        let cleanup = LandingTestSuspension()
        let task = Task<Void, Error> {
            for await _ in cancellation.stream {}
            await cleanup.suspend()
        }
        #expect(store.begin(seed()))
        store.attach(projectId: "p", task: task) {
            cancellation.continuation.finish()
        }

        store.prune(keepingProjectIds: [])
        await cleanup.waitUntilSuspended()

        let started = AsyncStream<Void>.makeStream()
        var didFinish = false
        let termination = Task { @MainActor in
            started.continuation.yield()
            started.continuation.finish()
            await store.cancelAllAndWait()
            didFinish = true
        }
        for await _ in started.stream { break }
        #expect(!didFinish)

        await cleanup.release()
        await termination.value
        #expect(didFinish)
        #expect(store.begin(seed()))
    }

    @Test func cancellationIgnoresLateFailureAndAppliesTerminalEntry() async {
        let store = GGLandingStore()
        store.begin(seed())
        let task = Task<Void, Error> { throw TestError.interrupted }
        store.attach(projectId: "p", task: task) {}
        store.cancel(projectId: "p")
        let outcome = GGLandedEntry(position: 1, prNumber: 41, action: "merged")
        store.receive(.entry(outcome), projectId: "p")
        store.fail(projectId: "p", message: "interrupted")

        await store.cancelAllAndWait()

        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["p"]?.rows[0].outcome == outcome)
    }
}
