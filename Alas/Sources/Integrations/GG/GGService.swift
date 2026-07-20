import Darwin
import Foundation
import Observation

/// Injectable gg process runner, mirroring `CodeHostCommandRunning` so
/// tests can fake CLI output. Local-only in phase 1 (no SSH rewrite).
protocol GGCommandRunning: Sendable {
    func run(args: [String], cwd: URL?) async throws -> ProcessResult
/// Streams stdout lines as they arrive (for `gg sync --jsonl`). Finishes
    /// with `.commandFailed`/`.cliMissing` on a non-zero exit.
    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error>
}

extension GGCommandRunning {
    /// Default: buffer the whole command then split into lines. Good enough
    /// for tests and any non-streaming conformer; `ProcessGGCommandRunner`
    /// overrides this with a truly incremental implementation.
    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await run(args: args, cwd: cwd)
                    for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true) {
                        continuation.yield(String(line))
                    }
                    if result.exitCode == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: GGServiceError.map(exitCode: result.exitCode, stderr: result.stderr))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

struct ProcessGGCommandRunner: GGCommandRunning {
    private static let commandTimeout: TimeInterval = 600

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        try await Process.run(
            "/usr/bin/env",
            args: ["gg"] + args,
            cwd: cwd,
            env: Process.gitEnv(),
            timeout: Self.commandTimeout
        )
    }

    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        Self.streamProcess(executable: "/usr/bin/env", args: ["gg"] + args, cwd: cwd, env: Process.gitEnv(), timeout: Self.commandTimeout)
    }

    /// Pipe-lifecycle core of `runStreaming`, parameterized on the
    /// executable/args so tests can exercise the readability-handler /
    /// write-end-close pattern against a trivial subprocess (e.g.
    /// `/bin/sh -c ...`) without depending on the `gg` binary being
    /// installed.
    static func streamProcess(
        executable: String,
        args: [String],
        cwd: URL?,
        env: [String: String]?,
        timeout: TimeInterval = Process.defaultTimeout
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = cwd }
            if let env { process.environment = env }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let buffer = LineBuffer()
            let stderrAccum = StderrAccumulator()
            let timeoutState = GGStreamingTimeoutState()
            // `terminationHandler` and these readability handlers are two
            // independent dispatch mechanisms with no ordering guarantee
            // between them: the child exiting does not imply the kernel has
            // already delivered the final EOF read to our handlers. Without
            // an explicit latch, `terminationHandler` can call
            // `continuation.finish()` before the stdout handler has flushed
            // `LineBuffer`'s trailing partial line (or before stderr has
            // appended its last chunk) — `finish()` makes any later `yield`
            // a silent no-op, so that last line is dropped, not delayed.
            // Mirrors `Process+Git.swift`'s `ByteAccumulator` EOF latch.
            let stdoutEOF = EOFLatch()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if let tail = buffer.flush() { continuation.yield(tail) }
                    stdoutEOF.markClosed()
                } else {
                    for line in buffer.feed(data) { continuation.yield(line) }
                }
            }
            // Drain stderr incrementally as it arrives rather than blocking
            // on it in the termination handler — see `Process+Git.swift`'s
            // `run(_:args:...)` for the same pattern and why it matters: a
            // chatty child can fill the ~64KB pipe buffer and block its own
            // `write()` (and therefore its own exit) if nobody is reading.
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    stderrAccum.markClosed()
                } else {
                    stderrAccum.append(data)
                }
            }
            process.terminationHandler = { proc in
                let status = proc.terminationStatus
                Task {
                    // Bound the wait the same way `Process+Git.swift` does:
                    // a stuck handler (e.g. a wedged dispatch queue) must
                    // not hang the stream forever.
                    async let outClosed = stdoutEOF.waitForClose(timeoutNanoseconds: 2_000_000_000)
                    async let errClosed = stderrAccum.waitForClose(timeoutNanoseconds: 2_000_000_000)
                    _ = await (outClosed, errClosed)
                    if timeoutState.didTimeOut {
                        continuation.finish(throwing: ProcessError.timedOut(executable: executable, args: args, seconds: timeout))
                    } else if status == 0 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: GGServiceError.map(exitCode: status, stderr: stderrAccum.text()))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish(throwing: GGServiceError.commandFailed(stderr: error.localizedDescription))
                return
            }
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if Task.isCancelled { return }
                if process.isRunning {
                    timeoutState.markTimedOut()
                    fputs(
                        "[Process watchdog] \(timeout)s timeout — terminating: \(executable) \(args.joined(separator: " "))\n",
                        stderr
                    )
                    terminateGGStreamingProcessWithEscalation(process)
                }
            }
            // Close the parent's copy of the pipe write ends now that the
            // child has dup'd them. Without this, the kernel keeps
            // reporting "writers still open" on the read side and the
            // readability handlers never see EOF after the child exits —
            // the stream would hang forever waiting for a termination that
            // already happened.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            continuation.onTermination = { _ in
                watchdog.cancel()
                if process.isRunning { process.terminate() }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
            }
        }
    }
}

private func terminateGGStreamingProcessWithEscalation(_ process: Process) {
    process.terminate()
    let pid = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
        if process.isRunning { kill(pid, SIGKILL) }
    }
}

private final class GGStreamingTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

/// EOF latch for a `FileHandle.readabilityHandler`: `markClosed()` from the
/// handler's EOF branch (empty `availableData`), `waitForClose(timeoutNanoseconds:)`
/// from an awaiter that must not proceed until EOF has actually been
/// observed. Latches `closed` so a waiter arriving after EOF (handler raced
/// ahead) returns immediately, and bounds the wait with a timeout so a
/// stuck handler can't hang the caller forever. Mirrors `Process+Git.swift`'s
/// `ByteAccumulator` (kept separate here since that type is file-private).
private final class EOFLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func markClosed() {
        lock.lock()
        let conts = Array(waiters.values)
        waiters = [:]
        closed = true
        lock.unlock()
        for c in conts { c.resume(returning: true) }
    }

    func waitForClose(timeoutNanoseconds: UInt64) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(returning: true)
                return
            }
            let id = UUID()
            waiters[id] = cont
            lock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.resumeTimedOutWaiter(id: id)
            }
        }
    }

    private func resumeTimedOutWaiter(id: UUID) {
        lock.lock()
        guard let cont = waiters.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        lock.unlock()
        cont.resume(returning: false)
    }
}

/// Thread-safe accumulator for stderr bytes read incrementally off a
/// readability handler, composed with an `EOFLatch` so callers can wait
/// until the handler has actually observed EOF before reading `text()`.
private final class StderrAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let eof = EOFLatch()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func markClosed() { eof.markClosed() }

    func waitForClose(timeoutNanoseconds: UInt64) async -> Bool {
        await eof.waitForClose(timeoutNanoseconds: timeoutNanoseconds)
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Stateless read-only facade over the gg CLI (peer to `GitService`).
struct GGService {
    var runner: GGCommandRunning = ProcessGGCommandRunner()

    /// Returns the gg version string ("0.9.8") or nil when gg is not
    /// installed / not on the login-shell PATH.
    func probeVersion() async -> String? {
        guard let result = try? await runner.run(args: ["--version"], cwd: nil),
              result.exitCode == 0
        else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // "gg 0.9.8" → "0.9.8"
        return output.split(separator: " ").last.map(String.init)
    }

    /// Loads the current branch's stack via `gg ls --json`. Returns nil
    /// when the branch is not a gg stack (gg emits the all-stacks shape).
    func currentStack(worktreePath: String) async throws -> GGStack? {
        let result: ProcessResult
        do {
            result = try await runner.run(
                args: ["ls", "--json"],
                cwd: URL(fileURLWithPath: worktreePath)
            )
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.commandFailed(stderr: String(describing: error))
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 127 { throw GGServiceError.map(exitCode: result.exitCode, stderr: result.stderr) }
            if let message = GGActionErrorMessage.parse(fromJSON: Data(result.stdout.utf8)) {
                throw GGServiceError.commandFailed(stderr: message)
            }
            throw GGServiceError.map(exitCode: result.exitCode, stderr: result.stderr)
        }
        return try GGStackSnapshot.decode(fromJSON: Data(result.stdout.utf8)).stack
    }

    /// Streams sync events when `gg sync --jsonl` is supported; older gg
    /// builds fall back to `--json` and yield a summary event on success.
    func sync(worktreePath: String) -> AsyncThrowingStream<GGSyncEvent, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if await syncSupportsJSONL() {
                        let lines = runner.runStreaming(
                            args: ["sync", "--jsonl"],
                            cwd: URL(fileURLWithPath: worktreePath)
                        )
                        for try await line in lines {
                            if let event = GGSyncEvent.parse(line: line) { continuation.yield(event) }
                        }
                    } else {
                        let result = try await runChecked(
                            args: ["sync", "--json"],
                            worktreePath: worktreePath
                        )
                        continuation.yield(GGSyncEvent.parse(line: result.stdout) ?? .summary)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Lands ready entries (bottom-up). `until` lands up to a target
    /// (position/GG-ID/SHA); nil lands all currently-approved entries.
    func land(worktreePath: String, until: String?) async throws -> GGLandResult {
        let args: [String] = until.map { ["land", "--until", $0, "--json", "--no-clean"] } ?? ["land", "--all", "--json", "--no-clean"]
        let result = try await runChecked(args: args, worktreePath: worktreePath)
        do {
            return try GGLandResult.decode(fromJSON: Data(result.stdout.utf8))
        } catch GGServiceError.malformedOutput {
            // Exit 0 means the land completed; JSON-shape drift must not
            // surface as a failure after the PRs were already merged.
            return GGLandResult(landed: [])
        }
        // A real in-band error (GGServiceError.commandFailed thrown by
        // decode) and anything else still propagate.
    }

    func clean(worktreePath: String) async throws {
        _ = try await runChecked(args: ["clean", "--all"], worktreePath: worktreePath)
    }

    private func syncSupportsJSONL() async -> Bool {
        guard let result = try? await runner.run(args: ["sync", "--help"], cwd: nil),
              result.exitCode == 0
        else { return false }
        return result.stdout.contains("--jsonl")
    }

    func continueOp(worktreePath: String) async throws {
        _ = try await runChecked(args: ["continue"], worktreePath: worktreePath)
    }

    func abortOp(worktreePath: String) async throws {
        _ = try await runChecked(args: ["abort"], worktreePath: worktreePath)
    }

    func checkout(worktreePath: String, target: String) async throws {
        _ = try await runChecked(args: ["mv", target], worktreePath: worktreePath)
    }

    /// Runs a gg command and maps a non-zero exit to `GGServiceError`, the
    /// same way `currentStack` does.
    private func runChecked(args: [String], worktreePath: String) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await runner.run(args: args, cwd: URL(fileURLWithPath: worktreePath))
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.commandFailed(stderr: String(describing: error))
        }
        guard result.exitCode == 0 else {
            if result.exitCode == 127 { throw GGServiceError.map(exitCode: result.exitCode, stderr: result.stderr) }
            if let message = GGActionErrorMessage.parse(fromJSON: Data(result.stdout.utf8)) {
                throw GGServiceError.commandFailed(stderr: message)
            }
            throw GGServiceError.map(exitCode: result.exitCode, stderr: result.stderr)
        }
        return result
    }
}

/// Session-cached gg availability, probed once at startup and re-probed
/// (force) after the Settings install flow completes.
@MainActor
@Observable
final class GGAvailability {
    static let shared = GGAvailability()

    private(set) var version: String?
    private(set) var hasProbed = false

    var isInstalled: Bool { version != nil }

    func probe(service: GGService = GGService(), force: Bool = false) async {
        if hasProbed && !force { return }
        version = await service.probeVersion()
        hasProbed = true
    }
}
