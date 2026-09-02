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
    typealias ProcessLaunch = @Sendable (
        _ executable: String,
        _ args: [String],
        _ cwd: URL?,
        _ env: [String: String]?,
        _ timeout: TimeInterval
    ) async throws -> ProcessResult

    private static let commandTimeout: TimeInterval = 600
    private let processLaunch: ProcessLaunch

    init(
        processLaunch: @escaping ProcessLaunch = { executable, args, cwd, env, timeout in
            try await Process.run(
                executable,
                args: args,
                cwd: cwd,
                env: env,
                timeout: timeout
            )
        }
    ) {
        self.processLaunch = processLaunch
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        return try await processLaunch(
            "/usr/bin/env",
            ["gg"] + args,
            cwd,
            Process.gitEnv(),
            Self.commandTimeout
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
            var processEnvironment = env ?? ProcessInfo.processInfo.environment
            let processTreeID = UUID().uuidString
            processEnvironment["ALAS_GG_PROCESS_TREE_ID"] = processTreeID
            process.environment = processEnvironment
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let buffer = LineBuffer()
            let stderrAccum = StderrAccumulator()
            let timeoutState = GGStreamingTimeoutState()
            let processTree = GGStreamingProcessTree(
                process: process,
                environmentMarker: "ALAS_GG_PROCESS_TREE_ID=\(processTreeID)"
            )
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
                processTree.rootDidExit()
                let status = proc.terminationStatus
                Task {
                    processTree.terminateAndWait()
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
                processTree.start()
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
                    processTree.terminateAndWait()
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
                processTree.terminateAndWait()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
            }
        }
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

    private static let supportedSchemaVersion = 1

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

    func probeCapabilities() async -> GGCapabilities {
        let root = try? await runner.run(args: ["--help"], cwd: nil)
        let split = try? await runner.run(args: ["split", "--help"], cwd: nil)
        let unstack = try? await runner.run(args: ["unstack", "--help"], cwd: nil)
        let sc = try? await runner.run(args: ["sc", "--help"], cwd: nil)
        let sync = try? await runner.run(args: ["sync", "--help"], cwd: nil)
        let ls = try? await runner.run(args: ["ls", "--help"], cwd: nil)
        return GGCapabilities(
            structuredSplit: split?.exitCode == 0
                && split?.stdout.contains("--describe") == true
                && split?.stdout.contains("--plan-json") == true,
            keepCurrentUnstack: unstack?.exitCode == 0
                && unstack?.stdout.contains("--keep-current") == true,
            clientOperationID: root?.exitCode == 0
                && root?.stdout.contains("--client-operation-id") == true,
            stagedOnlyAmend: sc?.exitCode == 0
                && sc?.stdout.contains("--staged-only") == true,
            syncJSONL: sync?.exitCode == 0 && sync?.stdout.contains("--jsonl") == true,
            localStackSnapshot: ls?.exitCode == 0
                && ls?.stdout.contains("--no-refresh") == true
        )
    }

    /// Loads the current branch's stack via `gg ls --json`. Returns nil
    /// when the branch is not a gg stack (gg emits the all-stacks shape).
    func currentStack(worktreePath: String, refreshRemote: Bool = true) async throws -> GGStack? {
        try await currentStackSnapshot(
            worktreePath: worktreePath,
            refreshRemote: refreshRemote
        ).stack
    }

    func currentStackSnapshot(
        worktreePath: String,
        refreshRemote: Bool = true
    ) async throws -> GGStackSnapshot {
        let result: ProcessResult
        do {
            result = try await runner.run(
                args: refreshRemote
                    ? ["ls", "--json"]
                    : ["ls", "--json", "--no-refresh"],
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
        return try GGStackSnapshot.decode(fromJSON: Data(result.stdout.utf8))
    }

    /// Streams cross-stack triage events from `gg inbox --jsonl`. Runs at the
    /// project root — one forge round-trip per project, never per worktree.
    /// Per-stack failures arrive in-band as `stackErrors`, not as thrown errors.
    func inboxStream(repoPath: String) -> AsyncThrowingStream<GGInboxEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var sawStart = false
                var sawSummary = false
                var fatalMessage: String?
                var totalCandidates: Int?
                var lastCompleted = 0

                do {
                    do {
                        for try await line in runner.runStreaming(
                            args: ["inbox", "--jsonl"],
                            cwd: URL(fileURLWithPath: repoPath)
                        ) {
                            guard !sawSummary else {
                                throw GGServiceError.malformedOutput("gg inbox emitted data after a terminal event.")
                            }
                            guard fatalMessage == nil else {
                                fatalMessage = nil
                                throw GGServiceError.malformedOutput("gg inbox emitted data after a terminal event.")
                            }
                            let event = try GGInboxEvent.decode(line: line)
                            switch event {
                            case .error(let message):
                                fatalMessage = message
                            case .start(let count, _):
                                guard !sawStart else {
                                    throw GGServiceError.malformedOutput("gg inbox emitted duplicate start events.")
                                }
                                sawStart = true
                                totalCandidates = count
                                continuation.yield(event)
                            case .entry(let payload):
                                try Self.validateInboxProgress(
                                    started: sawStart,
                                    expectedTotal: totalCandidates,
                                    completed: payload.completed,
                                    eventTotal: payload.totalCandidates,
                                    lastCompleted: &lastCompleted
                                )
                                continuation.yield(event)
                            case .entryError(let payload):
                                try Self.validateInboxProgress(
                                    started: sawStart,
                                    expectedTotal: totalCandidates,
                                    completed: payload.completed,
                                    eventTotal: payload.totalCandidates,
                                    lastCompleted: &lastCompleted
                                )
                                continuation.yield(event)
                            case .stackError:
                                guard sawStart else {
                                    throw GGServiceError.malformedOutput("gg inbox emitted stack_error before start.")
                                }
                                continuation.yield(event)
                            case .summary:
                                guard sawStart else {
                                    throw GGServiceError.malformedOutput("gg inbox emitted summary before start.")
                                }
                                sawSummary = true
                                continuation.yield(event)
                            }
                        }
                    } catch {
                        if let fatalMessage {
                            throw GGServiceError.commandFailed(stderr: fatalMessage)
                        }
                        throw error
                    }

                    if let fatalMessage {
                        throw GGServiceError.commandFailed(stderr: fatalMessage)
                    }
                    guard sawStart, sawSummary else {
                        throw GGServiceError.malformedOutput("gg inbox ended without a summary event.")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Streams sync events when the cached `--jsonl` capability is supported;
    /// older gg builds fall back to `--json` and yield a summary event on success.
    func sync(
        worktreePath: String,
        supportsJSONL: Bool
    ) -> AsyncThrowingStream<GGSyncEvent, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if supportsJSONL {
                        let lines = runner.runStreaming(
                            args: ["sync", "--jsonl"],
                            cwd: URL(fileURLWithPath: worktreePath)
                        )
                        var sawSummary = false
                        for try await line in lines {
                            let events = GGSyncEvent.parseEvents(line: line)
                            for event in events {
                                continuation.yield(event)
                            }
                            if events.contains(.summary) {
                                sawSummary = true
                                break
                            }
                        }
                        guard sawSummary else {
                            throw GGServiceError.malformedOutput(
                                "gg sync ended without a summary event."
                            )
                        }
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask {
                                for try await _ in lines {}
                            }
                            group.addTask {
                                // `streamProcess` may spend up to two seconds draining pipes after exit.
                                try await Task.sleep(nanoseconds: 2_500_000_000)
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                    } else {
                        let result = try await runChecked(
                            args: ["sync", "--json"],
                            worktreePath: worktreePath
                        )
                        let events = GGSyncEvent.parseEvents(line: result.stdout)
                        if events.isEmpty {
                            continuation.yield(.summary)
                        } else {
                            for event in events { continuation.yield(event) }
                        }
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
        let result = try await runAction(
            ["clean", "--all", "--json"],
            cwd: URL(fileURLWithPath: worktreePath)
        )
        do {
            _ = try decodeVersioned(GGCleanResponse.self, from: result)
        } catch GGServiceError.malformedOutput {
            // Exit 0 means clean completed. Older GG builds may not emit JSON.
        }
    }

    func amendCurrent(worktreePath: String) async throws {
        _ = try await runAction(
            ["sc", "--staged-only"],
            cwd: URL(fileURLWithPath: worktreePath)
        )
    }

    func absorbStaged(worktreePath: String) async throws {
        _ = try await runAction(["absorb", "-s"], cwd: URL(fileURLWithPath: worktreePath))
    }

    func drop(worktreePath: String, target: String) async throws -> GGDropResult {
        let result = try await runAction(
            ["drop", target, "--yes", "--json"],
            cwd: URL(fileURLWithPath: worktreePath)
        )
        return try decodeVersioned(GGDropResponse.self, from: result).drop
    }

    func unstack(
        worktreePath: String,
        target: String,
        name: String,
        createWorktree: Bool
    ) async throws -> GGUnstackResult {
        var args = [
            "unstack", "--target", target, "--name", name, "--no-tui", "--json",
        ]
        args.append(createWorktree ? "--worktree" : "--keep-current")
        let result = try await runAction(args, cwd: URL(fileURLWithPath: worktreePath))
        let wire = try decodeVersioned(GGUnstackResponse.self, from: result).unstack

        let currentStack: String
        if createWorktree {
            currentStack = wire.currentStack ?? wire.originalStack
        } else {
            guard let reportedCurrent = wire.currentStack else {
                throw GGServiceError.malformedOutput(
                    "gg unstack --keep-current did not report current_stack. Update gg and try again."
                )
            }
            guard reportedCurrent == wire.originalStack else {
                throw GGServiceError.malformedOutput(
                    "gg unstack --keep-current changed the current stack unexpectedly."
                )
            }
            currentStack = reportedCurrent
        }

        return GGUnstackResult(
            originalStack: wire.originalStack,
            newStack: wire.newStack,
            movedCommits: wire.movedEntries,
            worktreePath: wire.worktreePath,
            currentStack: currentStack
        )
    }

    func reorder(worktreePath: String, order: [String]) async throws {
        _ = try await runAction(
            ["reorder", "--order", order.joined(separator: ",")],
            cwd: URL(fileURLWithPath: worktreePath)
        )
    }

    func restack(worktreePath: String, dryRun: Bool) async throws -> GGRestackResult {
        var args = ["restack", "--json"]
        if dryRun { args.append("--dry-run") }
        let result = try await runAction(args, cwd: URL(fileURLWithPath: worktreePath))
        return try decodeVersioned(GGRestackResponse.self, from: result).restack
    }

    func rebase(worktreePath: String, target: String?) async throws {
        let args = ["rebase"] + (target.map { [$0] } ?? [])
        _ = try await runAction(args, cwd: URL(fileURLWithPath: worktreePath))
    }

    func listUndoOperations(worktreePath: String, limit: Int) async throws -> [GGOperationSummary] {
        let result = try await runAction(
            ["undo", "--list", "--json", "--limit", String(limit)],
            cwd: URL(fileURLWithPath: worktreePath)
        )
        return try decodeVersioned(GGUndoListResponse.self, from: result).operations
    }

    func undo(worktreePath: String, operationID: String) async throws -> GGUndoResult {
        let args = ["undo", operationID, "--json"]
        let cwd = URL(fileURLWithPath: worktreePath)
        let result = try await invoke(args, cwd: cwd)
        if result.exitCode == 127 {
            throw GGServiceError.cliMissing
        }
        if result.exitCode != 0,
           let refusal = try decodeUndoRefusal(from: result)
        {
            throw GGServiceError.undoRefused(
                message: refusal.message,
                hint: refusal.hints.isEmpty ? nil : refusal.hints.joined(separator: "\n")
            )
        }
        guard result.exitCode == 0 else { throw actionError(from: result) }

        let response = try decodeVersioned(GGUndoResponse.self, from: result)
        if let refusal = response.refusal {
            throw GGServiceError.undoRefused(
                message: refusal.message,
                hint: refusal.hints.isEmpty ? nil : refusal.hints.joined(separator: "\n")
            )
        }
        guard response.status == "succeeded", let undone = response.undone else {
            throw GGServiceError.malformedOutput("gg undo did not return the required undone operation.")
        }
        return GGUndoResult(undone: undone)
    }

    func describeSplit(worktreePath: String, target: String) async throws -> GGSplitDescription {
        let result = try await runAction(
            ["split", "--describe", "--commit", target, "--json"],
            cwd: URL(fileURLWithPath: worktreePath)
        )
        return try decodeVersioned(GGSplitDescription.self, from: result)
    }

    func applySplit(worktreePath: String, planURL: URL) async throws -> GGSplitApplyResult {
        let result = try await runAction(
            ["split", "--plan-json", planURL.path, "--json"],
            cwd: URL(fileURLWithPath: worktreePath)
        )
        return try decodeVersioned(GGSplitApplyResult.self, from: result)
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

    private static func validateInboxProgress(
        started: Bool,
        expectedTotal: Int?,
        completed: Int,
        eventTotal: Int,
        lastCompleted: inout Int
    ) throws {
        guard started, let expectedTotal else {
            throw GGServiceError.malformedOutput("gg inbox emitted an entry before start.")
        }
        guard eventTotal == expectedTotal else {
            throw GGServiceError.malformedOutput("gg inbox entry total did not match start total.")
        }
        guard lastCompleted < completed, completed <= eventTotal else {
            throw GGServiceError.malformedOutput("gg inbox emitted invalid entry progress.")
        }
        lastCompleted = completed
    }

    /// Runs a gg command and maps a non-zero exit to `GGServiceError`, the
    /// same way `currentStack` does.
    private func runChecked(args: [String], worktreePath: String) async throws -> ProcessResult {
        try await runAction(args, cwd: URL(fileURLWithPath: worktreePath))
    }

    private func invoke(_ args: [String], cwd: URL) async throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try await runner.run(args: args, cwd: cwd)
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.commandFailed(stderr: String(describing: error))
        }
        return result
    }

    private func runAction(_ args: [String], cwd: URL) async throws -> ProcessResult {
        let result = try await invoke(args, cwd: cwd)
        guard result.exitCode == 0 else { throw actionError(from: result) }
        return result
    }

    private func actionError(from result: ProcessResult) -> GGServiceError {
        if result.exitCode == 127 { return .cliMissing }
        let parsed = GGActionErrorMessage.parse(fromJSON: Data(result.stdout.utf8))
        let message = parsed
            ?? result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = message.lowercased()

        if normalized.contains("immutable commit") || normalized.contains("immutable target") {
            return .immutableTargets(message: message)
        }
        if normalized.contains("dirty working") || normalized.contains("working tree is dirty") {
            return .dirtyWorkingTree(message: message)
        }
        if normalized.contains("stale split plan") {
            return .staleSplitPlan(message: message)
        }
        if normalized.contains("stale target") {
            return .staleTarget(message: message)
        }
        if normalized.contains("conflict")
            && (normalized.contains("continue") || normalized.contains("abort") || normalized.contains("paused"))
        {
            return .pausedConflict(message: message)
        }
        if normalized.contains("partial mutation") || normalized.contains("partially mutated") {
            return .partialMutation(message: message)
        }
        return .commandFailed(stderr: message)
    }

    private func decodeVersioned<T: Decodable>(_ type: T.Type, from result: ProcessResult) throws -> T {
        let data = Data(result.stdout.utf8)
        let version: Int
        do {
            version = try JSONDecoder().decode(GGSchemaVersion.self, from: data).version
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
        guard version == Self.supportedSchemaVersion else {
            throw GGServiceError.unsupportedSchema(version)
        }
        if let message = GGActionErrorMessage.parse(fromJSON: data) {
            throw actionError(from: ProcessResult(exitCode: 1, stdout: result.stdout, stderr: message))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch let error as GGServiceError {
            throw error
        } catch {
            throw GGServiceError.malformedOutput(String(describing: error))
        }
    }

    private func decodeUndoRefusal(from result: ProcessResult) throws -> GGUndoRefusal? {
        do {
            let response = try decodeVersioned(GGUndoResponse.self, from: result)
            return response.status == "refused" ? response.refusal : nil
        } catch let error as GGServiceError {
            if case .unsupportedSchema = error { throw error }
            return nil
        }
    }
}

private struct GGSchemaVersion: Decodable {
    let version: Int
}

private struct GGCleanResponse: Decodable {
    struct Clean: Decodable {
        let cleaned: [String]
        let skipped: [String]
    }

    let clean: Clean
}

private struct GGDropResponse: Decodable {
    let drop: GGDropResult
}

private struct GGUnstackResponse: Decodable {
    struct Unstack: Decodable {
        let originalStack: String
        let newStack: String
        let movedEntries: [GGUnstackCommit]
        let worktreePath: String?
        let currentStack: String?
    }

    let unstack: Unstack
}

private struct GGRestackResponse: Decodable {
    let restack: GGRestackResult
}

private struct GGUndoListResponse: Decodable {
    let operations: [GGOperationSummary]
}

private struct GGUndoResponse: Decodable {
    let status: String
    let undone: GGOperationSummary?
    let refusal: GGUndoRefusal?
}

private struct GGUndoRefusal: Decodable {
    let message: String
    let hints: [String]

    private enum CodingKeys: String, CodingKey {
        case message, hints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
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
    private(set) var ggMCPBinaryPath: String?
    private(set) var capabilities = GGCapabilities(
        structuredSplit: false,
        keepCurrentUnstack: false
    )

    var isInstalled: Bool { version != nil }

    /// Resolves an executable path via `which` on the login-shell PATH.
    /// Never executes the target binary (gg-mcp is a stdio server that
    /// would block if run); `which` only resolves.
    static let defaultWhich: @Sendable (String) async -> String? = { name in
        guard let result = try? await Process.run(
            "/usr/bin/env", args: ["which", name], env: Process.gitEnv()
        ), result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    func probe(
        service: GGService = GGService(),
        which: @Sendable (String) async -> String? = GGAvailability.defaultWhich,
        force: Bool = false
    ) async {
        if hasProbed && !force { return }
        let detectedVersion = await service.probeVersion()
        let detectedMCPBinaryPath = detectedVersion != nil ? await which("gg-mcp") : nil
        let detectedCapabilities = detectedVersion != nil
            ? await service.probeCapabilities()
            : GGCapabilities(structuredSplit: false, keepCurrentUnstack: false)

        if version != detectedVersion { version = detectedVersion }
        if ggMCPBinaryPath != detectedMCPBinaryPath { ggMCPBinaryPath = detectedMCPBinaryPath }
        if capabilities != detectedCapabilities { capabilities = detectedCapabilities }
        if !hasProbed { hasProbed = true }
    }
}
