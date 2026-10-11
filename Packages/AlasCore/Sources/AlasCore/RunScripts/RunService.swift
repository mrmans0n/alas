import Foundation

/// Runs project scripts without a terminal. It executes the same captured
/// command a terminal run does, in a plain shell, and settles the run from
/// the completion file that command writes.
@MainActor
public final class RunService {
    /// Executes `shellScript` from `workingDirectory`, returning the shell's
    /// exit status once it has exited.
    public typealias Launch = @Sendable (_ shellScript: String, _ workingDirectory: URL) async throws -> Int32

    public enum RunError: Error, Equatable {
        /// The shell exited without writing the completion file, for example
        /// because the script removed the capture directory or the disk filled.
        case completionNotPublished(exitCode: Int32)
    }

    private let launch: Launch

    public init(launch: @escaping Launch = RunService.runInShell) {
        self.launch = launch
    }

    /// Runs the shell in its own process group with its output drained and
    /// discarded: the captured command already records the transcript, so
    /// nothing here grows with the script's output. Cancelling the calling
    /// task terminates the whole group and throws `CancellationError`.
    public static let runInShell: Launch = { shellScript, workingDirectory in
        let output = Pipe()
        output.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        let group = ShellGroup()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let process = try SpawnedProcess(
                        executable: URL(fileURLWithPath: "/bin/zsh"),
                        arguments: ["-c", shellScript],
                        environment: ProcessInfo.processInfo.environment,
                        directory: workingDirectory,
                        stdin: nil,
                        stdout: output,
                        stderr: output,
                        onExit: { _, termination in continuation.resume(returning: termination.status) }
                    )
                    group.started(process.pid)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            group.terminate()
        }
        try Task.checkCancellation()
        return status
    }

    /// Runs `script` in `worktree` on this machine and returns how it ended.
    public func run(
        _ script: RunScript,
        in worktree: Worktree,
        project: ProjectConfig,
        runID: String = UUID().uuidString
    ) async throws -> RunScriptCompletion {
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        let command = try RunScriptCommand.runScriptStartupScript(
            script: script,
            worktreeRoot: worktree.path,
            branch: worktree.branch,
            projectName: project.name,
            repoRoot: project.path,
            capturePaths: location.paths
        )
        let exitCode = try await launch(command, worktree.path)
        // The command publishes its completion file before the shell exits, so
        // a missing file now means it never will be.
        guard FileManager.default.fileExists(atPath: location.paths.completion) else {
            throw RunError.completionNotPublished(exitCode: exitCode)
        }
        return try await RunScriptCompletionMonitor.wait(for: location)
    }
}

/// The shell's process group, terminated on cancellation even when the
/// cancellation arrives before the shell has started.
private final class ShellGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false

    func started(_ pid: pid_t) {
        let cancelled = lock.withLock {
            self.pid = pid
            return self.cancelled
        }
        if cancelled { _ = kill(-pid, SIGTERM) }
    }

    func terminate() {
        let pid = lock.withLock {
            cancelled = true
            return self.pid
        }
        if let pid { _ = kill(-pid, SIGTERM) }
    }
}
