import Foundation
import Testing
@testable import AlasCore

#if canImport(Darwin)
struct ForkWatchTests {
    private struct Outcome: Sendable {
        var spawnFailures = 0
        var watchFailures = 0
        var reapFailures = 0
        var nonZeroExits = 0
        var missedExits = 0
    }

    @Test("process exit delivery survives concurrent observer cancellation")
    func exitDeliverySurvivesConcurrentCancellation() async throws {
        // The loop blocks in waitpid hundreds of times. It runs on its own
        // thread so it never holds a cooperative-pool thread that the
        // package's other async tests need to make progress.
        let outcome = await withCheckedContinuation { (done: CheckedContinuation<Outcome, Never>) in
            Thread { done.resume(returning: Self.spawnAndCancel(iterations: 256)) }.start()
        }
        #expect(outcome.spawnFailures == 0)
        #expect(outcome.watchFailures == 0)
        #expect(outcome.reapFailures == 0)
        #expect(outcome.nonZeroExits == 0)
        #expect(outcome.missedExits == 0)
    }

    /// Exit events the handler saw without the exit flag, counted from the
    /// dispatch queue that delivers them.
    private final class MissedExits: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private static func spawnAndCancel(iterations: Int) -> Outcome {
        let queue = DispatchQueue(label: "ForkWatchTests.exit", attributes: .concurrent)
        let executable = strdup("/usr/bin/true")!
        defer { free(executable) }
        let missed = MissedExits()
        var outcome = Outcome()
        // A process source can already be delivering its event when cancel
        // returns. Releasing the observer must keep that delivery safe.
        for _ in 0..<iterations {
            var pid: pid_t = 0
            var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
            let launched = arguments.withUnsafeMutableBufferPointer {
                posix_spawn(&pid, executable, nil, nil, $0.baseAddress!, environ)
            }
            guard launched == 0 else {
                outcome.spawnFailures += 1
                continue
            }
            var watch = ForkWatch.start(pid: pid, watchExit: true, queue: queue) { exited in
                if !exited { missed.increment() }
            }
            if watch == nil { outcome.watchFailures += 1 }
            watch?.resume()
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            if reaped != pid { outcome.reapFailures += 1 }
            if status != 0 { outcome.nonZeroExits += 1 }
            watch?.cancel()
            watch = nil
        }
        queue.sync(flags: .barrier) {}
        outcome.missedExits = missed.count
        return outcome
    }
}
#endif
