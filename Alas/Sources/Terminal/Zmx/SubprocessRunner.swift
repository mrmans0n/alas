import Foundation

/// Tiny injectable seam over `Foundation.Process`. Exists so `ZmxClient` can
/// be unit-tested without spawning real processes, and to centralize the
/// timeout + pipe-drainage discipline in one place.
struct SubprocessRunner: Sendable {
    struct Result: Equatable, Sendable {
        /// nil → spawn failed or watchdog timed out before exit.
        let exitCode: Int32?
        let stdout: String
        let stderr: String
    }

    /// `run(executable, args, env, timeout)`.
    var run: @Sendable (URL, [String], [String: String], TimeInterval) -> Result

    /// Real implementation. 5s default timeout is enforced per call.
    static let system = SubprocessRunner { executable, args, env, timeout in
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain each pipe with a blocking `readDataToEndOfFile()` on its own
        // background queue. This avoids the readabilityHandler race where
        // `waitUntilExit()` can return before the asynchronous EOF callback
        // has flushed the final buffered chunk — and it still prevents
        // pipe-buffer deadlocks because the readers run concurrently with
        // the child. The reader groups are joined AFTER process exit (or
        // forced termination), giving us a synchronization point with EOF
        // delivery before we read the accumulated output.
        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let stdoutDrain = DispatchGroup()
        let stderrDrain = DispatchGroup()
        stdoutDrain.enter()
        stderrDrain.enter()
        DispatchQueue.global().async {
            defer { stdoutDrain.leave() }
            stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        }
        DispatchQueue.global().async {
            defer { stderrDrain.leave() }
            stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        }

        do {
            try process.run()
        } catch {
            // Spawn failed: close the pipe write ends so the drain threads
            // hit EOF and exit, then wait for them.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            stdoutDrain.wait()
            stderrDrain.wait()
            return Result(exitCode: nil, stdout: "", stderr: "\(error)")
        }

        let deadline = DispatchTime.now() + timeout
        let exitGroup = DispatchGroup()
        exitGroup.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            exitGroup.leave()
        }
        let waitResult = exitGroup.wait(timeout: deadline)
        if waitResult == .timedOut {
            process.terminate()
            _ = exitGroup.wait(timeout: .now() + .milliseconds(250))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitGroup.wait(timeout: .now() + .milliseconds(250))
            }
            // Child is dead → its pipe write ends are closed → drain threads
            // observe EOF and exit. Join them so we read complete buffers.
            stdoutDrain.wait()
            stderrDrain.wait()
            return Result(exitCode: nil, stdout: stdoutBox.string(), stderr: stderrBox.string())
        }

        // Process exited normally; pipe write ends are closed, drains will
        // hit EOF. Join before reading the boxes.
        stdoutDrain.wait()
        stderrDrain.wait()
        return Result(
            exitCode: process.terminationStatus,
            stdout: stdoutBox.string(),
            stderr: stderrBox.string()
        )
    }
}

/// Thread-safe accumulator for pipe output. The pipe reader callbacks fire
/// on arbitrary background queues, so all access is serialized through a
/// lock. Returning `String` (not `Data`) at read time keeps consumers simple.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
