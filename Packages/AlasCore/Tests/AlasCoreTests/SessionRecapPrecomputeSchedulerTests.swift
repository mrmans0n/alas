import Foundation
import Testing
@testable import AlasCore

/// Every wait is on an event the scheduler must produce, so a regression
/// would hang; the time limit turns that into a failure.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionRecapPrecomputeSchedulerTests {
    /// A sleeper the test resumes by hand. Each call is announced on `calls`
    /// with its index and requested duration; cancellation throws.
    private actor FakeSleeper {
        private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]
        private var nextIndex = 0
        nonisolated let calls: AsyncStream<(index: Int, duration: Duration)>
        private let callsContinuation: AsyncStream<(index: Int, duration: Duration)>.Continuation

        init() {
            (calls, callsContinuation) = AsyncStream.makeStream()
        }

        func sleep(_ duration: Duration) async throws {
            let index = nextIndex
            nextIndex += 1
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending[index] = continuation
                    callsContinuation.yield((index, duration))
                }
            } onCancel: {
                Task { await self.cancel(index) }
            }
        }

        func resume(_ index: Int) {
            pending.removeValue(forKey: index)?.resume()
        }

        private func cancel(_ index: Int) {
            pending.removeValue(forKey: index)?.resume(throwing: CancellationError())
        }
    }

    /// Records runs and holds each one open until the test finishes it,
    /// even when cancelled, which it reports on `cancellations`.
    @MainActor
    private final class FakeRunner {
        private(set) var started: [String] = []
        private var finishers: [String: CheckedContinuation<SessionRecapPrecomputeOutcome, Never>] = [:]
        let starts: AsyncStream<String>
        private let startsContinuation: AsyncStream<String>.Continuation
        let cancellations: AsyncStream<String>
        private let cancellationsContinuation: AsyncStream<String>.Continuation

        init() {
            (starts, startsContinuation) = AsyncStream.makeStream()
            (cancellations, cancellationsContinuation) = AsyncStream.makeStream()
        }

        func run(_ sessionId: String) async -> SessionRecapPrecomputeOutcome {
            started.append(sessionId)
            let cancellations = cancellationsContinuation
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    finishers[sessionId] = continuation
                    startsContinuation.yield(sessionId)
                }
            } onCancel: {
                cancellations.yield(sessionId)
            }
        }

        func finish(_ sessionId: String, _ outcome: SessionRecapPrecomputeOutcome = .stored) {
            finishers.removeValue(forKey: sessionId)?.resume(returning: outcome)
        }
    }

    private static let now = Date(timeIntervalSince1970: 100_000)
    private static let threshold: Duration = .seconds(300)

    private let sleeper = FakeSleeper()
    private let runner = FakeRunner()
    private let scheduler: SessionRecapPrecomputeScheduler

    init() {
        let sleeper = sleeper
        let runner = runner
        scheduler = SessionRecapPrecomputeScheduler(
            now: { Self.now },
            sleep: { try await sleeper.sleep($0) },
            run: { await runner.run($0) }
        )
    }

    private func next<T: Sendable>(_ stream: AsyncStream<T>) async throws -> T {
        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        return try #require(value)
    }

    private func pastDue(_ minutesAgo: Double) -> Date {
        Self.now.addingTimeInterval(-minutesAgo * 60)
    }

    @Test
    func entryRunsOnlyOnceItsThresholdElapses() async throws {
        scheduler.schedule(sessionId: "A", lastSeenAt: Self.now, threshold: Self.threshold)

        let call = try await next(sleeper.calls)
        #expect(call.duration == Self.threshold)
        #expect(scheduler.runningSessionId == nil)
        #expect(scheduler.pendingSessionIds == ["A"])

        await sleeper.resume(call.index)
        #expect(try await next(runner.starts) == "A")
        #expect(scheduler.pendingSessionIds.isEmpty)
    }

    @Test
    func droppingBeforeTheThresholdNeverRuns() async throws {
        scheduler.schedule(sessionId: "A", lastSeenAt: Self.now, threshold: Self.threshold)
        let call = try await next(sleeper.calls)

        scheduler.drop(sessionId: "A")
        #expect(scheduler.pendingSessionIds.isEmpty)
        await sleeper.resume(call.index)

        // A later due entry runs, and it is the only run.
        scheduler.schedule(sessionId: "B", lastSeenAt: pastDue(60), threshold: Self.threshold)
        #expect(try await next(runner.starts) == "B")
        #expect(runner.started == ["B"])
    }

    @Test
    func droppingTheRunningJobCancelsItButTheNextStillWaitsForItToReturn() async throws {
        scheduler.isSuspended = true
        scheduler.schedule(sessionId: "running", lastSeenAt: pastDue(30), threshold: Self.threshold)
        scheduler.schedule(sessionId: "queued", lastSeenAt: pastDue(60), threshold: Self.threshold)
        scheduler.isSuspended = false
        #expect(try await next(runner.starts) == "running")

        scheduler.drop(sessionId: "running")
        #expect(try await next(runner.cancellations) == "running")
        #expect(scheduler.runningSessionId == "running")
        #expect(scheduler.pendingSessionIds == ["queued"])

        runner.finish("running")
        #expect(try await next(runner.starts) == "queued")
    }

    /// Entries due in the same turn compete for the first slot, so the one
    /// scheduled first does not jump ahead of a more recently seen one.
    @Test
    func dueEntriesRunMostRecentlySeenFirstAndOneAtATime() async throws {
        scheduler.schedule(sessionId: "older", lastSeenAt: pastDue(60), threshold: Self.threshold)
        scheduler.schedule(sessionId: "newer", lastSeenAt: pastDue(30), threshold: Self.threshold)

        let first = try await next(runner.starts)
        #expect(first == "newer")
        #expect(scheduler.runningSessionId == first)
        #expect(scheduler.pendingSessionIds.count == 1)

        runner.finish(first)
        _ = try await next(runner.starts)
        #expect(runner.started == ["newer", "older"])
    }

    @Test
    func preemptedJobBacksOffThenRetriesBeforeTheRest() async throws {
        scheduler.schedule(sessionId: "older", lastSeenAt: pastDue(60), threshold: Self.threshold)
        scheduler.schedule(sessionId: "newer", lastSeenAt: pastDue(30), threshold: Self.threshold)
        #expect(try await next(runner.starts) == "newer")

        runner.finish("newer", .preempted)
        let backoff = try await next(sleeper.calls)
        #expect(backoff.duration == SessionRecapPrecomputeScheduler.preemptionBackoff)
        #expect(scheduler.runningSessionId == nil)
        #expect(scheduler.pendingSessionIds == ["newer", "older"])
        #expect(runner.started == ["newer"])

        await sleeper.resume(backoff.index)
        #expect(try await next(runner.starts) == "newer")
        runner.finish("newer")
        #expect(try await next(runner.starts) == "older")
        #expect(runner.started == ["newer", "newer", "older"])
    }

    @Test
    func suspensionHoldsDueJobsUntilLifted() async throws {
        scheduler.isSuspended = true
        scheduler.schedule(sessionId: "A", lastSeenAt: pastDue(60), threshold: Self.threshold)
        #expect(scheduler.runningSessionId == nil)
        #expect(scheduler.pendingSessionIds == ["A"])

        scheduler.isSuspended = false
        #expect(scheduler.runningSessionId == "A")
        #expect(try await next(runner.starts) == "A")
    }
}
