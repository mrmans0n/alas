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

        // Resolve when the child exits, regardless of how — clean exit,
        // signal, or our SIGTERM via the watchdog. Setting the handler
        // *before* `run()` means we never miss the event.
        let exit = ExitGate()
        process.terminationHandler = { _ in exit.didExit() }

        // Read stdout/stderr via readability handlers. We deliberately
        // avoid `readDataToEndOfFile` on a `Task.detached` because on
        // macos-26 CI it has been observed to hang past child exit
        // (parent's copy of the pipe write end can keep the reader
        // blocked, and forcing-close the read end while a syscall is in
        // flight is racy). Handlers buffer chunks as they arrive and
        // detach themselves on EOF, so once the child exits and the
        // kernel delivers EOF we stop reading immediately.
        let outAccum = ByteAccumulator()
        let errAccum = ByteAccumulator()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outAccum.markClosed()
            } else {
                outAccum.append(data)
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errAccum.markClosed()
            } else {
                errAccum.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        // Close the parent's copy of the pipe write ends now that the
        // child has dup'd them. Without this, the kernel keeps reporting
        // "writers still open" on the read side and the readability
        // handler never sees EOF after the child exits.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        // Watchdog. If we time out, SIGTERM the process; the
        // terminationHandler will fire and `exit.wait()` returns.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            fputs(
                "[Process watchdog] \(timeout)s timeout — terminating: \(executable) \(args.joined(separator: " "))\n",
                stderr
            )
            if process.isRunning { process.terminate() }
        }

        await exit.wait()
        watchdog.cancel()

        // Brief grace period for any in-flight readability dispatches to
        // land before we snapshot. EOF after exit is queued in the kernel
        // pipe immediately, but the handler dispatch has some tail
        // latency under CI load — 50ms is enough in practice. Using a
        // plain `Task.sleep` instead of an `NSCondition` avoids a
        // user-initiated QoS thread waiting on a default-QoS handler
        // (the priority inversion that prompted past CI hangs).
        try? await Task.sleep(nanoseconds: 50_000_000)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let timedOut = process.terminationReason == .uncaughtSignal
        if timedOut {
            throw ProcessError.timedOut(executable: executable, args: args, seconds: timeout)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outAccum.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: errAccum.snapshot(), encoding: .utf8) ?? ""
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

/// Resolves once `didExit()` is called. Safe to call `didExit` before any
/// awaiter has parked (handler runs on a background queue; the awaiter
/// arrives from the calling task).
private final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?

    func didExit() {
        lock.lock()
        if let c = continuation {
            continuation = nil
            lock.unlock()
            c.resume()
            return
        }
        exited = true
        lock.unlock()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited {
                lock.unlock()
                cont.resume()
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}

/// Lock-protected `Data` buffer for output collected from the readability
/// handler.
private final class ByteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func markClosed() {
        // No-op — the snapshot path takes whatever we've accumulated.
        // Kept for symmetry with `append` so the handler logic stays
        // self-documenting.
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
