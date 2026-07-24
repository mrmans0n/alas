import Darwin
import Foundation

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessError: Error {
    case launchFailed(String)
    case timedOut(executable: String, args: [String], seconds: TimeInterval)
    case nonZeroExit(Int32, String)
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
        stdin: String? = nil,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResult {
        try validateLaunchConfiguration(executable: executable, args: args, cwd: cwd)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }

        let stdinWriter = stdin.map(StdinPipeWriter.init)
        let inputPipe = stdinWriter.map { _ in Pipe() }
        let outPipe = Pipe()
        let errPipe = Pipe()
        if let inputPipe { process.standardInput = inputPipe }
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
        let timeoutState = TimeoutState()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            if process.isRunning {
                timeoutState.markTimedOut()
                stdinWriter?.close()
                fputs(
                    "[Process watchdog] \(timeout)s timeout — terminating: \(executable) \(args.joined(separator: " "))\n",
                    stderr
                )
                terminateProcessWithEscalation(process)
            }
        }

        if let inputPipe {
            stdinWriter?.start(pipe: inputPipe)
        }

        // SIGTERM the child if the awaiting Task is cancelled. The
        // terminationHandler will fire from the kernel-delivered exit and
        // resolve the ExitGate, so `exit.wait()` returns normally and we
        // fall through to read accumulated output / report a non-zero exit
        // code — same recovery path as the watchdog uses on timeout.
        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            stdinWriter?.close()
            terminateProcessWithEscalation(process)
        }
        watchdog.cancel()
        stdinWriter?.close()

        // Wait for both pipes to actually report EOF before we drop the
        // readability handlers — a fixed grace period would truncate
        // output for commands that emit a lot post-exit or run on a
        // congested dispatch queue. The accumulators resolve their
        // continuation when the handler delivers an empty buffer (EOF);
        // we cap the wait at 2s to bound a worst-case stuck handler.
        async let outClosed = outAccum.waitForClose(timeoutNanoseconds: 2_000_000_000)
        async let errClosed = errAccum.waitForClose(timeoutNanoseconds: 2_000_000_000)
        _ = await (outClosed, errClosed)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let timedOut = timeoutState.didTimeOut
        if timedOut {
            throw ProcessError.timedOut(executable: executable, args: args, seconds: timeout)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outAccum.snapshot(), encoding: .utf8) ?? "",
            stderr: String(data: errAccum.snapshot(), encoding: .utf8) ?? ""
        )
    }

    /// Builds the environment for every git invocation Alas spawns.
    ///
    /// Starts from the parent process env (so `PATH`, `HOME`, etc. work) and
    /// sets `GIT_OPTIONAL_LOCKS=0`. The latter tells git not to take
    /// optional locks like `.git/index.lock` on read-class commands
    /// (`status`, `diff`, ...). Without it, alas's background monitoring
    /// loop fights terminal git (`gg sync`, `git commit`) for the index
    /// lock and the terminal call fails with
    /// `fatal: Unable to create '.git/index.lock': File exists.`
    ///
    /// This dict is applied to the *child* process only — we never
    /// `setenv` on Alas itself — so the embedded Ghostty terminal (which
    /// builds its env from `ProcessInfo.processInfo.environment` via
    /// `EnvBuilder`) is unaffected and user-typed `git` commands behave
    /// exactly as they would in any other terminal.
    static func gitEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Force git to emit messages in English. We parse stderr in several
        // places (e.g. WorktreeService submodule/dirty/LFS matchers) and those
        // matchers are English-only; a user with `LANG=es_ES.UTF-8` would
        // otherwise hit translated errors that no matcher recognizes. POSIX:
        // LC_ALL overrides LC_MESSAGES and LANG, so this is sufficient.
        env["LC_ALL"] = "C"
        if let shellPath = ShellEnvResolver.shared.resolvedPath {
            env["PATH"] = shellPath
        }
        return env
    }

    /// Convenience wrapper that always uses `/usr/bin/env git` with the
    /// optional-locks-suppressed env from `gitEnv()`.
    static func git(
        _ args: [String],
        cwd: URL? = nil,
        stdin: String? = nil,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResult {
        let host = RemoteHostRegistry.shared.host(forPath: cwd?.path)
        if host == nil {
            try validateWorkingDirectory(cwd)
        }
        let invocation = GitInvocation.build(
            gitArgs: args,
            cwd: cwd,
            host: host
        )
        return try await run(
            invocation.executable,
            args: invocation.args,
            cwd: invocation.cwd,
            env: invocation.env,
            stdin: stdin,
            timeout: timeout
        )
    }
}

struct ProcessResultData: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String
}

extension Process {
    /// Same as `git(_:cwd:stdin:timeout:)` but returns stdout as raw `Data`
    /// instead of UTF-8 `String`. Use this for `git show <ref>:<path>` on
    /// binary blobs (images, etc.) where UTF-8 decoding would corrupt the
    /// payload.
    static func gitData(
        _ args: [String],
        cwd: URL? = nil,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResultData {
        let host = RemoteHostRegistry.shared.host(forPath: cwd?.path)
        if host == nil {
            try validateWorkingDirectory(cwd)
        }
        let invocation = GitInvocation.build(
            gitArgs: args,
            cwd: cwd,
            host: host
        )
        return try await runData(
            invocation.executable,
            args: invocation.args,
            cwd: invocation.cwd,
            env: invocation.env,
            timeout: timeout
        )
    }

    /// Internal: same shape as `run(...)` but emits stdout as `Data`.
    static func runData(
        _ executable: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        timeout: TimeInterval = Process.defaultTimeout
    ) async throws -> ProcessResultData {
        try validateLaunchConfiguration(executable: executable, args: args, cwd: cwd)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        if let env { process.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let exit = ExitGateData()
        process.terminationHandler = { _ in exit.didExit() }

        let outAccum = ByteAccumulatorData()
        let errAccum = ByteAccumulatorData()
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

        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        let timedOutFlag = TimedOutFlag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if Task.isCancelled { return }
            if process.isRunning {
                timedOutFlag.mark()
                fputs(
                    "[Process watchdog] \(timeout)s timeout — terminating: \(executable) \(args.joined(separator: " "))\n",
                    stderr
                )
                terminateProcessWithEscalation(process)
            }
        }

        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            terminateProcessWithEscalation(process)
        }
        watchdog.cancel()

        async let outClosed = outAccum.waitForClose(timeoutNanoseconds: 2_000_000_000)
        async let errClosed = errAccum.waitForClose(timeoutNanoseconds: 2_000_000_000)
        _ = await (outClosed, errClosed)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if timedOutFlag.value {
            throw ProcessError.timedOut(executable: executable, args: args, seconds: timeout)
        }

        return ProcessResultData(
            exitCode: process.terminationStatus,
            stdout: outAccum.snapshot(),
            stderr: String(data: errAccum.snapshot(), encoding: .utf8) ?? ""
        )
    }
}

private let maximumFoundationProcessArgumentCount = 4096

private func validateLaunchConfiguration(executable: String, args: [String], cwd: URL?) throws {
    guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw ProcessError.launchFailed("Executable is not runnable: \(executable)")
    }
    guard args.count <= maximumFoundationProcessArgumentCount else {
        throw ProcessError.launchFailed(
            "Too many arguments: \(args.count) (maximum \(maximumFoundationProcessArgumentCount))"
        )
    }

    try validateWorkingDirectory(cwd)
}

private func validateWorkingDirectory(_ cwd: URL?) throws {
    guard let cwd else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ProcessError.launchFailed("Working directory does not exist: \(cwd.path)")
    }
}

private func terminateProcessWithEscalation(_ process: Process) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    process.terminate()
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        if process.isRunning {
            kill(pid, SIGKILL)
        }
    }
}

private final class TimedOutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.lock()
    defer { lock.unlock() }
    return v }
    func mark() { lock.lock()
    v = true
    lock.unlock() }
}

private final class ExitGateData: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var continuation: CheckedContinuation<Void, Never>?
    func didExit() {
        lock.lock()
        if let c = continuation { continuation = nil
        lock.unlock()
        c.resume()
        return }
        exited = true
        lock.unlock()
    }
    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if exited { lock.unlock()
            cont.resume()
            return }
            continuation = cont
            lock.unlock()
        }
    }
}

private final class ByteAccumulatorData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    func append(_ chunk: Data) { lock.lock()
    data.append(chunk)
    lock.unlock() }
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
            if closed { lock.unlock()
            cont.resume(returning: true)
            return }
            let id = UUID()
            waiters[id] = cont
            lock.unlock()
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.timeOut(id: id)
            }
        }
    }
    private func timeOut(id: UUID) {
        lock.lock()
        guard let c = waiters.removeValue(forKey: id) else { lock.unlock()
        return }
        lock.unlock()
        c.resume(returning: false)
    }
    func snapshot() -> Data { lock.lock()
    defer { lock.unlock() }
    return data }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

private final class StdinPipeWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var offset = 0
    private var closed = false
    private weak var handle: FileHandle?
    private let chunkSize = 16 * 1024

    init(_ stdin: String) {
        self.data = Data(stdin.utf8)
    }

    func start(pipe: Pipe) {
        let writeHandle = pipe.fileHandleForWriting
        lock.lock()
        guard !closed else {
            lock.unlock()
            try? writeHandle.close()
            return
        }
        handle = writeHandle
        if data.isEmpty {
            closed = true
            handle = nil
            lock.unlock()
            try? writeHandle.close()
            return
        }
        lock.unlock()

        writeHandle.writeabilityHandler = { [weak self] handle in
            self?.writeAvailable(handle)
        }
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let writeHandle = handle
        handle = nil
        lock.unlock()

        writeHandle?.writeabilityHandler = nil
        try? writeHandle?.close()
    }

    private func writeAvailable(_ writeHandle: FileHandle) {
        let chunk: Data?
        lock.lock()
        if closed || offset >= data.count {
            closed = true
            handle = nil
            lock.unlock()
            writeHandle.writeabilityHandler = nil
            try? writeHandle.close()
            return
        }
        let end = min(offset + chunkSize, data.count)
        chunk = data[offset..<end]
        offset = end
        let didFinish = offset >= data.count
        if didFinish {
            closed = true
            handle = nil
        }
        lock.unlock()

        if let chunk {
            writeHandle.write(chunk)
        }
        if didFinish {
            writeHandle.writeabilityHandler = nil
            try? writeHandle.close()
        }
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

/// Lock-protected `Data` buffer with an EOF latch. The readability
/// handler calls `markClosed` when it sees an empty buffer (EOF); a single
/// awaiter on `waitForClose` resumes there. Latches `closed` so an
/// awaiter that arrives *after* EOF (handler raced ahead) returns
/// immediately.
private final class ByteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var closed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

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

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
