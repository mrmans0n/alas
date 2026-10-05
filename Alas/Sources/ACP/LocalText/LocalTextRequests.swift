import Foundation

/// Preference changes cancel owned requests synchronously, including those
/// that have not reached the native engine yet. A later request stays untouched.
@MainActor
final class LocalTextRequests<Value: Sendable> {
    private var tracked: Set<Task<Value, Never>> = []

    func track(_ job: Task<Value, Never>) { tracked.insert(job) }
    func finish(_ job: Task<Value, Never>) { tracked.remove(job) }

    func cancelAll() {
        tracked.forEach { $0.cancel() }
        tracked.removeAll()
    }
}
