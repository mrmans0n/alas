import Foundation
import Testing
@testable import Alas

@Suite("RunHistoryPersistenceRetry")
struct RunHistoryPersistenceRetryTests {
    private struct ProbeError: Error, Equatable {}

    @Test("succeeds without sleeping when the first attempt succeeds")
    func firstAttemptSuccess() async throws {
        let attempts = LockedCounter()
        let slept = LockedCounter()
        let result = try await RunHistoryPersistenceRetry.attempt(sleep: { slept.increment() }) {
            attempts.increment()
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts.count == 1)
        #expect(slept.count == 0)
    }

    @Test("retries once after a failure and returns the recovered result")
    func retriesOnceThenSucceeds() async throws {
        let attempts = LockedCounter()
        let slept = LockedCounter()
        let result = try await RunHistoryPersistenceRetry.attempt(sleep: { slept.increment() }) {
            if attempts.increment() == 1 { throw ProbeError() }
            return "recovered"
        }
        #expect(result == "recovered")
        #expect(attempts.count == 2)
        #expect(slept.count == 1)
    }

    @Test("propagates the failure when both attempts fail, without retrying a third time")
    func bothAttemptsFail() async throws {
        let attempts = LockedCounter()
        await #expect(throws: ProbeError.self) {
            try await RunHistoryPersistenceRetry.attempt(sleep: {}) {
                attempts.increment()
                throw ProbeError()
            }
        }
        #expect(attempts.count == 2)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments and returns the new value.
    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
