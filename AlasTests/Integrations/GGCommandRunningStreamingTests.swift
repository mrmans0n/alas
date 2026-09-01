import Foundation
import Testing
@testable import Alas

/// Exercises `ProcessGGCommandRunner`'s pipe-lifecycle handling (readability
/// handlers on both stdout/stderr, closing the parent's write ends after
/// `process.run()`) against a trivial `/bin/sh` subprocess. This does not
/// depend on the `gg` binary being installed.
///
/// Every test wraps its `for try await` consumption in a timeout so a
/// regression back to the missing-write-end-close deadlock (or a blocking
/// `readDataToEndOfFile` on stderr) fails the test visibly instead of
/// hanging the suite forever.
struct GGCommandRunningStreamingTests {
    private func collectWithTimeout(
        _ stream: AsyncThrowingStream<String, Error>,
        seconds: UInt64 = 5
    ) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                var lines: [String] = []
                for try await line in stream { lines.append(line) }
                return lines
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private struct TimeoutError: Error {}

    @Test func streamsStdoutLinesInOrderAndFinishesOnCleanExit() async throws {
        let script = "printf 'one\\ntwo\\nthree\\n'"
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            env: nil
        )
        let lines = try await collectWithTimeout(stream)
        #expect(lines == ["one", "two", "three"])
    }

    @Test func preservesUTF8ScalarsSplitAcrossReads() async throws {
        let script = "printf '\\303'; sleep 0.1; printf '\\251\\n'"
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            env: nil
        )
        let lines = try await collectWithTimeout(stream)
        #expect(lines == ["é"])
    }

    @Test func streamingRunTimesOutHungProcess() async throws {
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", "sleep 2"],
            cwd: nil,
            env: nil,
            timeout: 0.1
        )
        await #expect(throws: ProcessError.self) {
            _ = try await collectWithTimeout(stream)
        }
    }

    @Test func cancelingStreamKillsProcessThatIgnoresTermination() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stream-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        var env = ProcessInfo.processInfo.environment
        env["PID_FILE"] = pidFile.path
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", "trap '' TERM; echo $$ > \"$PID_FILE\"; while :; do :; done"],
            cwd: nil,
            env: env
        )
        let consumer = Task {
            for try await _ in stream {}
        }
        defer { consumer.cancel() }

        var discoveredProcessID: pid_t?
        for _ in 0 ..< 50 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                discoveredProcessID = pid
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let processID = try #require(discoveredProcessID)
        defer { kill(processID, SIGKILL) }

        consumer.cancel()
        _ = try? await consumer.value

        var isRunning = true
        for _ in 0 ..< 150 {
            if kill(processID, 0) == -1, errno == ESRCH {
                isRunning = false
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!isRunning)
    }

    @Test func nonZeroExitSurfacesCommandFailedWithAccumulatedStderr() async throws {
        let script = "echo boom 1>&2; exit 3"
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            env: nil
        )
        await #expect(throws: GGServiceError.commandFailed(stderr: "boom")) {
            _ = try await collectWithTimeout(stream)
        }
    }

    @Test func exit127MapsToCLIMissing() async throws {
        let script = "exit 127"
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            env: nil
        )
        await #expect(throws: GGServiceError.cliMissing) {
            _ = try await collectWithTimeout(stream)
        }
    }

    /// A chatty-stderr child (larger than the ~64KB pipe buffer) must not
    /// deadlock the child's own exit. Regresses the "no readability handler
    /// on stderr" finding: without draining stderr incrementally, the
    /// child's `write()` blocks once the pipe fills, it never exits, and
    /// this test times out.
    /// `process.terminationHandler` and the stdout/stderr readability
    /// handlers are two independent async dispatch mechanisms with no
    /// ordering guarantee between them. A trailing unterminated line only
    /// gets flushed from `LineBuffer` on EOF — if the termination handler
    /// finished the continuation before that EOF flush happened, `c` would
    /// be silently dropped (`yield` is a documented no-op after `finish()`).
    /// Writing the last line with no trailing newline immediately before
    /// `exit 0` (no delay) is the most race-prone shape: it maximizes the
    /// chance the child has already exited by the time the readability
    /// handler gets scheduled to drain the final chunk.
    @Test func trailingUnterminatedLineSurvivesTerminationRace() async throws {
        let script = "printf 'a\\nb\\nc'; exit 0"
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            env: nil
        )
        let lines = try await collectWithTimeout(stream)
        #expect(lines == ["a", "b", "c"])
    }

    @Test func largeStderrDoesNotDeadlockChildExit() async throws {
        // ~200KB of stderr output, comfortably over the OS pipe buffer.
        // `head`'s own stdout (not `yes`'s) is redirected to stderr so the
        // pipe still carries `yes`'s output into `head`'s stdin.
        let script = "yes boom | head -c 200000 1>&2; exit 1"
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", script],
            cwd: nil,
            env: nil
        )
        await #expect(throws: GGServiceError.self) {
            _ = try await collectWithTimeout(stream, seconds: 10)
        }
    }
}
