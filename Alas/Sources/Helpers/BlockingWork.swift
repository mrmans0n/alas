import Foundation

/// Runs blocking work — process spawns and waits, pipe reads, sleep loops —
/// on a thread of its own.
///
/// The Swift concurrency cooperative pool has one thread per core, and
/// `Task.detached` runs there too. Work that blocks a pool thread for long
/// starves unrelated tasks, and a few such jobs can take the whole pool.
enum BlockingWork {
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            // A detached thread has no autorelease pool of its own.
            Thread.detachNewThread { continuation.resume(returning: autoreleasepool { body() }) }
        }
    }

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run { Result { try body() } }.get()
    }

    /// Fire-and-forget variant for callers that do not wait for the result.
    static func detach(_ body: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { autoreleasepool { body() } }
    }
}
