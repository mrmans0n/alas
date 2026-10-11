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

        // Drain each pipe incrementally. A descendant can retain an inherited
        // writer after the direct child exits, so EOF is not a reliable
        // prerequisite for returning the output emitted so far.
        let stdoutBox = OutputBox()
        let stderrBox = OutputBox()
        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutBox.markClosed()
            } else {
                stdoutBox.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrBox.markClosed()
            } else {
                stderrBox.append(data)
            }
        }

        func finishDrainingPipes() {
            let pipes = [
                (stdoutBox, stdoutPipe.fileHandleForReading),
                (stderrBox, stderrPipe.fileHandleForReading),
            ]
            for (output, reader) in pipes {
                _ = output.waitForClose(timeout: .now() + .milliseconds(250))
                reader.readabilityHandler = nil
            }
        }

        do {
            try process.run()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            finishDrainingPipes()
            return Result(exitCode: nil, stdout: "", stderr: "\(error)")
        }

        // Without closing our copies after Process duplicates them into the
        // child, a normal direct-child exit can never produce EOF here.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let deadline = DispatchTime.now() + timeout
        let waitResult = exitSemaphore.wait(timeout: deadline)
        if waitResult == .timedOut {
            process.terminate()
            _ = exitSemaphore.wait(timeout: .now() + .milliseconds(250))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSemaphore.wait(timeout: .now() + .milliseconds(250))
            }
            finishDrainingPipes()
            process.terminationHandler = nil
            return Result(exitCode: nil, stdout: stdoutBox.string(), stderr: stderrBox.string())
        }

        finishDrainingPipes()
        process.terminationHandler = nil
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
    private var closed = false
    private let closeGroup = DispatchGroup()

    init() {
        closeGroup.enter()
    }

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

    func markClosed() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        closeGroup.leave()
    }

    func waitForClose(timeout: DispatchTime) -> DispatchTimeoutResult {
        closeGroup.wait(timeout: timeout)
    }
}
