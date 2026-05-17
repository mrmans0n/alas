import Foundation
import Testing
@testable import Alas

/// Test helper that converts the socket server's fire-and-forget
/// `onEvent` callback into an awaitable. Avoids `Task.sleep` + read
/// races: the event dispatch hops to the main queue, and under
/// parallel test load the dispatched block may not run before a fixed
/// sleep deadline. `wait` suspends until a matching event fires (or
/// times out). A composite hook command emits multiple events on one
/// invocation; pass a predicate to wait for the one you care about.
final class EventHolder: @unchecked Sendable {
    private struct PendingWaiter {
        let id: UUID
        let predicate: (AgentHookEvent) -> Bool
        let continuation: CheckedContinuation<AgentHookEvent?, Never>
    }

    private let lock = NSLock()
    private var events: [AgentHookEvent] = []
    private var pending: [PendingWaiter] = []

    func deliver(_ event: AgentHookEvent) {
        lock.lock()
        events.append(event)
        let matching = pending.filter { $0.predicate(event) }
        pending.removeAll { waiter in
            matching.contains { $0.id == waiter.id }
        }
        lock.unlock()

        for waiter in matching {
            waiter.continuation.resume(returning: event)
        }
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
            let id = UUID()
            pending.append(PendingWaiter(id: id, predicate: predicate, continuation: cont))
            lock.unlock()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                self?.timeoutPendingWaiter(id: id)
            }
        }
    }

    private func timeoutPendingWaiter(id: UUID) {
        lock.lock()
        let index = pending.firstIndex { $0.id == id }
        let waiter = index.map { pending.remove(at: $0) }
        lock.unlock()
        waiter?.continuation.resume(returning: nil)
    }
}

struct EventHolderTests {
    @Test func concurrentWaitersCompleteIndependently() async {
        let holder = EventHolder()

        async let busy = holder.wait(timeoutMs: 1000) { $0.event == .busy }
        async let idle = holder.wait(timeoutMs: 1000) { $0.event == .idle }

        try? await Task.sleep(nanoseconds: 10_000_000)
        holder.deliver(Self.event(.idle))
        holder.deliver(Self.event(.busy))

        let received = await (busy, idle)
        #expect(received.0?.event == .busy)
        #expect(received.1?.event == .idle)
    }

    private static func event(_ event: ActivityEvent) -> AgentHookEvent {
        AgentHookEvent(
            version: 1,
            event: event,
            agent: .codex,
            sessionId: "test-session",
            pid: nil,
            timestamp: nil,
            body: nil
        )
    }
}
