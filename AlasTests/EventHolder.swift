import Foundation
@testable import Alas

/// Test helper that converts the socket server's fire-and-forget
/// `onEvent` callback into an awaitable. Avoids `Task.sleep` + read
/// races: the event dispatch hops to the main queue, and under
/// parallel test load the dispatched block may not run before a fixed
/// sleep deadline. `wait` suspends until a matching event fires (or
/// times out). A composite hook command emits multiple events on one
/// invocation; pass a predicate to wait for the one you care about.
final class EventHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentHookEvent] = []
    private var pending: (predicate: (AgentHookEvent) -> Bool,
                          continuation: CheckedContinuation<AgentHookEvent?, Never>)?

    func deliver(_ event: AgentHookEvent) {
        lock.lock()
        events.append(event)
        if let pending, pending.predicate(event) {
            self.pending = nil
            lock.unlock()
            pending.continuation.resume(returning: event)
            return
        }
        lock.unlock()
    }

    /// Waits up to `timeoutMs` for an event matching `predicate`. Returns
    /// the matching event, or nil on timeout. Default predicate matches any.
    func wait(
        timeoutMs: UInt64,
        where predicate: @escaping (AgentHookEvent) -> Bool = { _ in true }
    ) async -> AgentHookEvent? {
        await withCheckedContinuation { (cont: CheckedContinuation<AgentHookEvent?, Never>) in
            lock.lock()
            if let match = events.first(where: predicate) {
                lock.unlock()
                cont.resume(returning: match)
                return
            }
            pending = (predicate, cont)
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                self?.timeoutPendingWaiter()
            }
        }
    }

    private func timeoutPendingWaiter() {
        lock.lock()
        let p = pending
        pending = nil
        lock.unlock()
        p?.continuation.resume(returning: nil)
    }
}
