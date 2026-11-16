import Foundation
import Testing
@testable import AlasCore

#if canImport(Darwin)
struct ForkWatchTests {
    @Test("process exit delivery survives concurrent observer cancellation")
    func exitDeliverySurvivesConcurrentCancellation() throws {
        let queue = DispatchQueue(label: "ForkWatchTests.exit", attributes: .concurrent)
        let executable = strdup("/usr/bin/true")!
        defer { free(executable) }
        // A process source can already be delivering its event when cancel
        // returns. Releasing the observer must keep that delivery safe.
        for _ in 0..<256 {
            var pid: pid_t = 0
            var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
            let launched = arguments.withUnsafeMutableBufferPointer {
                posix_spawn(&pid, executable, nil, nil, $0.baseAddress!, environ)
            }
            try #require(launched == 0)
            var watch = ForkWatch.start(pid: pid, watchExit: true, queue: queue) { exited in
                #expect(exited)
            }
            try #require(watch != nil)
            watch?.resume()
            var status: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR
            #expect(reaped == pid)
            #expect(status == 0)
            watch?.cancel()
            watch = nil
        }
        queue.sync(flags: .barrier) {}
    }
}
#endif
