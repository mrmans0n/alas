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

    /// Runs the shell with its output discarded: the captured command already
    /// records the transcript, so nothing here grows with the script's output.
    public static let runInShell: Launch = { shellScript, workingDirectory in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", shellScript]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
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
