import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Runs project scripts without a terminal. It executes the same captured
/// command a terminal run does, in a plain shell, and settles the run from
/// the completion file that command writes.
@MainActor
public final class RunService {
    /// Executes `shellScript` from `workingDirectory`, returning the shell's
    /// exit status once it has exited.
    public typealias Launch = @Sendable (_ shellScript: String, _ workingDirectory: URL) async throws -> Int32

    /// The shell never started, so nothing ran.
    public struct NeverStarted: Error {
        public let underlying: any Error
    }

    public enum RunError: Error, Equatable {
        /// The shell exited without writing the completion file, for example
        /// because the script removed the capture directory or the disk filled.
        case completionNotPublished(exitCode: Int32)
        /// The project lives on another host; only local runs are supported.
        case remoteProjectUnsupported
        /// The script is already running in this worktree.
        case alreadyRunning
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
                        onExit: { _, termination in
                            group.exited()
                            continuation.resume(returning: termination.status)
                        }
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
        guard project.host == nil else { throw RunError.remoteProjectUnsupported }
        let location = try RunScriptCompletionMonitor.paths(runID: runID, host: nil)
        let command = try RunScriptCommand.runScriptStartupScript(
            script: script,
            worktreeRoot: worktree.path,
            branch: worktree.branch,
            projectName: project.name,
            repoRoot: project.path,
            capturePaths: location.paths,
            executionIdentity: RunScriptExecutionIdentity(runID: runID, worktreeID: worktree.id, projectID: project.id)
        )
        let exitCode: Int32
        do {
            exitCode = try await launch(command, worktree.path)
        } catch is CancellationError {
            RunScriptCompletionMonitor.removeLocalCapture(location.paths)
            throw CancellationError()
        } catch {
            // A launch reports how the shell exited; throwing means it never ran.
            RunScriptCompletionMonitor.removeLocalCapture(location.paths)
            throw NeverStarted(underlying: error)
        }
        // The command publishes its completion file before the shell exits, so
        // a missing file now means it never will be.
        guard FileManager.default.fileExists(atPath: location.paths.completion) else {
            RunScriptCompletionMonitor.removeLocalCapture(location.paths)
            throw RunError.completionNotPublished(exitCode: exitCode)
        }
        return try await RunScriptCompletionMonitor.wait(for: location)
    }
}

/// The shell's process tree, terminated on cancellation even when the
/// cancellation arrives before the shell has started. `/usr/bin/script` runs
/// the command in a session of its own, outside the shell's process group, so
/// cancellation signals the group and every descendant found under the shell.
/// SIGTERM goes first. If the shell is still running after a grace period,
/// the group and the descendants get SIGKILL, and whatever is left gets
/// SIGKILL when a cancelled shell exits. The group is only signalled before
/// the shell is reaped, and descendants are matched by start time, so a
/// reused pid is never hit.
private final class ShellGroup: @unchecked Sendable {
    static let killGrace: DispatchTimeInterval = .seconds(2)

    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false
    private var hasExited = false
    private var descendants: Set<ACPTerminal.DescendantKey> = []

    func started(_ pid: pid_t) {
        let cancelled = lock.withLock {
            self.pid = pid
            return self.cancelled
        }
        if cancelled { terminate(pid) }
    }

    func terminate() {
        let pid = lock.withLock {
            cancelled = true
            return self.pid
        }
        if let pid { terminate(pid) }
    }

    /// Runs on the reaper thread before the shell is reaped.
    func exited() {
        let pid = lock.withLock {
            hasExited = true
            return cancelled ? self.pid : nil
        }
        guard let pid else { return }
        _ = kill(-pid, SIGKILL)
        signalDescendants(SIGKILL)
    }

    private func terminate(_ pid: pid_t) {
        signal(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) { [self] in
            signal(pid, SIGKILL)
        }
    }

    /// Signals the group and the descendants while the shell is unreaped;
    /// holding the lock keeps it from being reaped in between.
    private func signal(_ pid: pid_t, _ signal: Int32) {
        lock.withLock {
            guard !hasExited else { return }
            descendants.formUnion(ACPTerminal.collectChildDescendants(of: pid))
            _ = kill(-pid, signal)
        }
        signalDescendants(signal)
    }

    private func signalDescendants(_ signal: Int32) {
        let known = lock.withLock { descendants }
        for key in ACPTerminal.currentlyMatching(known) {
            _ = kill(key.pid, signal)
        }
    }
}
