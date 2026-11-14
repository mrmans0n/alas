import Foundation
import Testing
@testable import AlasCore

@MainActor
struct HeldCallsTests {
    /// The hold limit never passes; other sleeps return at once.
    private static let untilCancelled: @MainActor (Duration) async -> Void = { _ in
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await withTaskCancellationHandler {
            for await _ in stream {}
        } onCancel: {
            continuation.finish()
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    @Test func releasesInArrivalOrderRunningOnReleaseFirst() async throws {
        let holds = HeldCalls(sleep: Self.untilCancelled)
        var released: [String] = []
        var outcomes: [Task<HeldCalls.Outcome, Never>] = []
        for session in ["a", "b", "c"] {
            outcomes.append(Task { await holds.hold("vm", sessionID: session) { released.append(session) } })
            try await waitUntil { holds.waiting("vm").last == session }
        }
        holds.releaseAll("vm")
        #expect(released == ["a", "b", "c"])
        for outcome in outcomes { #expect(await outcome.value == .released) }
        #expect(holds.waiting("vm").isEmpty)
    }

    @Test func aHoldTimesOut() async {
        let holds = HeldCalls(sleep: { _ in })
        #expect(await holds.hold("vm", sessionID: "a") == .timedOut)
        #expect(holds.waiting("vm").isEmpty)
    }

    @Test func aCancelledHoldLeavesTheQueue() async throws {
        let holds = HeldCalls(sleep: Self.untilCancelled)
        let first = Task { await holds.hold("vm", sessionID: "a") }
        try await waitUntil { holds.waiting("vm") == ["a"] }
        let second = Task { await holds.hold("vm", sessionID: "b") }
        try await waitUntil { holds.waiting("vm") == ["a", "b"] }
        first.cancel()
        #expect(await first.value == .cancelled)
        try await waitUntil { holds.waiting("vm") == ["b"] }
        holds.releaseAll("vm")
        #expect(await second.value == .released)
    }

    @Test func keysAreIndependent() async throws {
        let holds = HeldCalls(sleep: Self.untilCancelled)
        let other = Task { await holds.hold("y", sessionID: "a") }
        try await waitUntil { holds.waiting("y") == ["a"] }
        holds.releaseAll("x")
        #expect(holds.waiting("y") == ["a"])
        holds.releaseAll("y")
        #expect(await other.value == .released)
    }
}
