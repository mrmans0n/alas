import Foundation
import Testing
@testable import AlasCore
@testable import AlasHostCore

struct DataDirectoryLockTests {
    /// One holder at a time: a second taker is told who holds the lock, and
    /// takes it once the first lets go.
    @Test func aHeldDirectoryNamesItsHolderUntilReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: DataDirectoryLock? = try DataDirectoryLock.acquire(in: directory)

        #expect(throws: DataDirectoryLock.Refusal.held(pid: getpid())) {
            _ = try DataDirectoryLock.acquire(in: directory)
        }

        first = nil
        _ = first
        // Polled: a child another test is spawning right now briefly shares
        // this process's descriptors, the lock's among them, until the
        // kernel closes them on exec.
        try await eventually { (try? DataDirectoryLock.acquire(in: directory)) != nil }
    }

    /// A waiting taker blocks while the directory is held and takes it as
    /// soon as the holder lets go, as the launch agent's host waits for the app.
    @Test func aWaitingTakerGetsTheDirectoryOnceReleased() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alas-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: DataDirectoryLock? = try DataDirectoryLock.acquire(in: directory)
        // The lock is exclusive, so the waiter cannot return before `first`
        // lets go; without waiting it would refuse at once.
        let waiter = Task.detached { try DataDirectoryLock.acquire(in: directory, waiting: true) }
        first = nil
        _ = first
        let second = try await waiter.value
        #expect(second.url == directory.appendingPathComponent("host.lock"))
    }
}
