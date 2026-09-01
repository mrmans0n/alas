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

    @Test func watchdogAllowsGracefulTerminationBeforeKilling() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        var env = ProcessInfo.processInfo.environment
        env["TERM_MARKER"] = marker.path
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", "trap 'echo term > \"$TERM_MARKER\"; exit 0' TERM; while :; do sleep 0.05; done"],
            cwd: nil,
            env: env,
            timeout: 0.1
        )

        await #expect(throws: ProcessError.self) {
            _ = try await collectWithTimeout(stream)
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func watchdogKillsDetachedChildSpawnedByTerminationHandler() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-term-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        var env = ProcessInfo.processInfo.environment
        env["CHILD_PID_FILE"] = childPIDFile.path
        let script = #"import os,signal,time; handler=lambda *_: spawn(); spawn=lambda: (os.fork() and os._exit(0)) or (os.setsid(), signal.signal(signal.SIGTERM, signal.SIG_IGN), open(os.environ['CHILD_PID_FILE'],'w').write(str(os.getpid())), time.sleep(30)); signal.signal(signal.SIGTERM, handler); time.sleep(30)"#
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/usr/bin/python3",
            args: ["-c", script],
            cwd: nil,
            env: env,
            timeout: 0.2
        )

        _ = try? await collectWithTimeout(stream)
        let childPID = try #require(pid_t(try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(childPID, SIGKILL) }
        for _ in 0 ..< 50 where kill(childPID, 0) == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test func naturalExitKillsLastMinuteDetachedChild() async throws {
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-exit-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        var env = ProcessInfo.processInfo.environment
        env["CHILD_PID_FILE"] = childPIDFile.path
        let script = #"import os,signal,time; time.sleep(0.2); pid=os.fork(); time.sleep(0.05) if pid else None; os._exit(0) if pid else None; os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN); open(os.environ['CHILD_PID_FILE'],'w').write(str(os.getpid())); time.sleep(30)"#
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/usr/bin/python3",
            args: ["-c", script],
            cwd: nil,
            env: env
        )

        _ = try await collectWithTimeout(stream)
        let childPID = try #require(pid_t(try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(childPID, SIGKILL) }
        #expect(kill(childPID, 0) == -1 && errno == ESRCH)
    }

    @Test func cancelingStreamKillsProcessThatIgnoresTermination() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stream-\(UUID().uuidString).pid")
        let childPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-stream-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        defer { try? FileManager.default.removeItem(at: childPIDFile) }
        var env = ProcessInfo.processInfo.environment
        env["PID_FILE"] = pidFile.path
        env["CHILD_PID_FILE"] = childPIDFile.path
        env["PYTHON_CODE"] = #"import os,signal,time; time.sleep(0.2); pid=os.fork(); time.sleep(0.2) if pid else None; os._exit(0) if pid else None; os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN); f=open(os.environ['CHILD_PID_FILE'],'w'); f.write(str(os.getpid())); f.flush(); time.sleep(30)"#
        let stream = ProcessGGCommandRunner.streamProcess(
            executable: "/bin/sh",
            args: ["-c", #"/usr/bin/python3 -c "$PYTHON_CODE"; while [ ! -s "$CHILD_PID_FILE" ]; do sleep 0.01; done; echo $$ > "$PID_FILE"; while :; do sleep 1; done"#],
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
        let childProcessID = try #require(pid_t(try String(contentsOf: childPIDFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(processID, SIGKILL) }
        defer { kill(childProcessID, SIGKILL) }

        consumer.cancel()
        _ = try? await consumer.value
        #expect(kill(processID, 0) == -1)
        #expect(errno == ESRCH)
        for _ in 0 ..< 50 where kill(childProcessID, 0) == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(kill(childProcessID, 0) == -1 && errno == ESRCH)
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
