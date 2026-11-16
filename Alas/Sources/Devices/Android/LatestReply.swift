import Foundation

/// A reply to the latest request only: a newer request ends the one before it
/// with nil, and a timeout ends only the request that set it.
@MainActor
final class LatestReply<Value: Sendable> {
    private var waiter: (id: Int, continuation: CheckedContinuation<Value?, Never>)?
    private var nextID = 0
    private let sleep: @MainActor (Duration) async -> Void

    init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Runs `ask`, then waits for `deliver`; nil after `timeout` or when replaced.
    func request(timeout: Duration, ask: () -> Void) async -> Value? {
        nextID += 1
        let id = nextID
        resolve(nil)
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
        resolve(value)
    }

    /// Ends whatever waits, with nil.
    func cancel() {
        resolve(nil)
    }

    private func end(_ id: Int) {
        guard waiter?.id == id else { return }
        resolve(nil)
    }

    private func resolve(_ value: Value?) {
        let current = waiter
        waiter = nil
        current?.continuation.resume(returning: value)
    }
}
