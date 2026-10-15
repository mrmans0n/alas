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

    /// Records runs and holds each one open until the test finishes it.
    @MainActor
    private final class FakeRunner {
        private(set) var started: [String] = []
        private var finishers: [String: CheckedContinuation<Void, Never>] = [:]
        let starts: AsyncStream<String>
        private let startsContinuation: AsyncStream<String>.Continuation

        init() {
            (starts, startsContinuation) = AsyncStream.makeStream()
        }

        func run(_ sessionId: String) async {
            started.append(sessionId)
            await withCheckedContinuation { continuation in
                finishers[sessionId] = continuation
                startsContinuation.yield(sessionId)
            }
        }

        func finish(_ sessionId: String) {
            finishers.removeValue(forKey: sessionId)?.resume()
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

    @Test(arguments: ["seen", "busy", "closed"])
    func droppingBeforeTheThresholdNeverRuns(reason: String) async throws {
        scheduler.schedule(sessionId: "A", lastSeenAt: Self.now, threshold: Self.threshold)
        let call = try await next(sleeper.calls)

        scheduler.drop(sessionId: "A")
        #expect(scheduler.pendingSessionIds.isEmpty, "dropped as \(reason)")
        await sleeper.resume(call.index)

        // A later due entry runs, and it is the only run.
        scheduler.schedule(sessionId: "B", lastSeenAt: pastDue(60), threshold: Self.threshold)
        #expect(try await next(runner.starts) == "B")
        #expect(runner.started == ["B"])
    }

    @Test
    func dueEntriesRunMostRecentlySeenFirstAndOneAtATime() async throws {
        scheduler.isSuspended = true
        scheduler.schedule(sessionId: "older", lastSeenAt: pastDue(60), threshold: Self.threshold)
        scheduler.schedule(sessionId: "newer", lastSeenAt: pastDue(30), threshold: Self.threshold)
        #expect(scheduler.pendingSessionIds == ["newer", "older"])
        scheduler.isSuspended = false

        let first = try await next(runner.starts)
        #expect(first == "newer")
        #expect(scheduler.runningSessionId == first)
        #expect(scheduler.pendingSessionIds.count == 1)

        runner.finish(first)
        _ = try await next(runner.starts)
        #expect(runner.started == ["newer", "older"])
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
