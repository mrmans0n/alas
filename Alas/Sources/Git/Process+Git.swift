import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessError: Error {
    case launchFailed(String)
    case timedOut(executable: String, args: [String], seconds: TimeInterval)
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var timedOut = false
    private var stdoutClosed = false
    private var stderrClosed = false

    func appendStdout(_ data: Data) {
        lock.lock()
        stdout.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        lock.lock()
        stderr.append(data)
        lock.unlock()
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func markStdoutClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stdoutClosed else { return false }
        stdoutClosed = true
        return true
    }

    func markStderrClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stderrClosed else { return false }
        stderrClosed = true
        return true
    }

    func snapshot() -> (stdout: Data, stderr: Data, timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr, timedOut)
    }
}

private func waitForPipeEOF(_ group: DispatchGroup) -> DispatchTimeoutResult {
    group.wait(timeout: .now() + 1)
}

extension Process {
    /// Hard cap on how long a child process may run before we SIGTERM it.
    /// Macos-26 CI exposed several pathological hangs in `git` (credential
    /// helper, pager spawn, etc.) where a normally-millisecond invocation
    /// blocked indefinitely. Without a per-call cap the whole xcodebuild
    /// step would time out 8min later, hiding *which* call was stuck and
    /// starving downstream test steps.
    static let defaultTimeout: TimeInterval = 30

    static func run(
        _ executable: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let output = ProcessOutputBuffer()
        let eofGroup = DispatchGroup()
        eofGroup.enter()
        eofGroup.enter()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                if output.markStdoutClosed() { eofGroup.leave() }
                return
            }
            output.appendStdout(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                if output.markStderrClosed() { eofGroup.leave() }
                return
            }
            output.appendStderr(data)
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        // Watchdog: if the process is still running past `timeout`, SIGTERM
        // it AND force-close our read ends of the pipes. The pipe-close is
        // critical: `git worktree remove` (and other commands) can spawn
        // helpers that inherit the pipe write ends; SIGTERM on the direct
        // child leaves those helpers alive, the kernel never delivers EOF,
        // and `readDataToEndOfFile` blocks forever. Closing the read FD on
        // our side makes any in-flight read unblock immediately.
        let watchdog = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return  // cancelled — process exited cleanly
            }
            // Visible marker so a CI hang past 30s is unambiguously diagnosed.
            fputs(
                "[Process watchdog] \(timeout)s timeout — terminating: \(executable) \(args.joined(separator: " "))\n",
                stderr
            )
            output.markTimedOut()
            if process.isRunning { process.terminate() }
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
        }

        await Task.detached {
            process.waitUntilExit()
        }.value
        _ = await Task.detached {
            waitForPipeEOF(eofGroup)
        }.value

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        watchdog.cancel()

        let snapshot = output.snapshot()

        if snapshot.timedOut {
            throw ProcessError.timedOut(executable: executable, args: args, seconds: timeout)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: snapshot.stdout, encoding: .utf8) ?? "",
            stderr: String(data: snapshot.stderr, encoding: .utf8) ?? ""
        )
    }

    /// Convenience wrapper that always uses `/usr/bin/env git`.
    static func git(
        _ args: [String],
        cwd: URL? = nil,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResult {
        try await run("/usr/bin/env", args: ["git"] + args, cwd: cwd, timeout: timeout)
    }
}
