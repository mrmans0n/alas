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

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error.localizedDescription)
        }

        // Watchdog: if the process is still running past `timeout`, SIGTERM
        // it. Termination closes the child's pipe write ends, which unblocks
        // the readDataToEndOfFile readers below so we can return.
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }

        async let outData = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }.value
        async let errData = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }.value

        let out = await outData
        let err = await errData
        process.waitUntilExit()

        let timedOut = !watchdog.isCancelled && process.terminationReason == .uncaughtSignal
        watchdog.cancel()

        if timedOut {
            throw ProcessError.timedOut(executable: executable, args: args, seconds: timeout)
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: out, encoding: .utf8) ?? "",
            stderr: String(data: err, encoding: .utf8) ?? ""
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
