import Foundation

/// Why a request for the latest asynchronous reply ended.
enum LatestReplyOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case replaced
    case cancelled

    var value: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

/// A reply to the latest request only: a newer request replaces the one before
/// it, and a timeout ends only the request that set it.
@MainActor
final class LatestReply<Value: Sendable> {
    private var waiter: (id: Int, continuation: CheckedContinuation<LatestReplyOutcome<Value>, Never>)?
    private var nextID = 0
    private let sleep: @MainActor (Duration) async -> Void

    init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Runs `ask`, then waits for a value, timeout, replacement, or cancellation.
    func request(timeout: Duration, ask: () -> Void) async -> LatestReplyOutcome<Value> {
        nextID += 1
        let id = nextID
        resolve(.replaced)
        return await withCheckedContinuation { continuation in
            waiter = (id, continuation)
            ask()
            Task { [weak self, sleep] in
                await sleep(timeout)
                self?.end(id)
            }
        }
    }

    func deliver(_ value: Value) {
        resolve(.value(value))
    }

    func cancel() {
        resolve(.cancelled)
    }

    private func end(_ id: Int) {
        guard waiter?.id == id else { return }
        resolve(.timedOut)
    }

    private func resolve(_ outcome: LatestReplyOutcome<Value>) {
        let current = waiter
        waiter = nil
        current?.continuation.resume(returning: outcome)
    }
}
