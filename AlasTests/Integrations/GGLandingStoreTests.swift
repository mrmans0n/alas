import Foundation
import Testing
@testable import Alas

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
        _ = await task.result
        for _ in 0..<20 where store.sessions["p"]?.phase != .cancelled {
            await Task.yield()
        }
        #expect(cancelCount == 1)
        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["p"]?.error == nil)
    }

    @Test func unexpectedExitWithoutSummaryFailsSession() async {
        let store = GGLandingStore()
        store.begin(seed())
        let task = Task<Void, Error> {}
        store.attach(projectId: "p", task: task) {}

        _ = await task.result
        for _ in 0..<20 where store.sessions["p"]?.phase == .running {
            await Task.yield()
        }

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
        _ = await task.result

        #expect(cancelCount == 1)
        #expect(store.sessions["p"] == nil)
        #expect(store.sessions["other"]?.phase == .running)
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

        _ = await task.result
        for _ in 0..<20 where store.sessions["p"]?.phase != .cancelled {
            await Task.yield()
        }

        #expect(store.sessions["p"]?.phase == .cancelled)
        #expect(store.sessions["p"]?.rows[0].outcome == outcome)
    }
}
