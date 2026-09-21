import Foundation

/// Retries a run-history SQLite write once after a short delay before giving
/// up. Transient disk conditions (e.g. a momentarily full volume) commonly
/// clear by the very next attempt on the same connection, so a single retry
/// avoids surfacing an alarming "Run History Failed" alert for what is often
/// a self-resolving hiccup.
enum RunHistoryPersistenceRetry {
    static func attempt<T: Sendable>(
        sleep: @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(300))
        },
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            await sleep()
            return try await operation()
        }
    }
}
