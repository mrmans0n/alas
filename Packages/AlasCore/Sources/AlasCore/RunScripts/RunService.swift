import Foundation

/// Runs project scripts without a terminal. It executes the same captured
/// command a terminal run does, in a plain shell, and settles the run from
/// the completion file that command writes.
@MainActor
public final class RunService {
    /// Executes `shellScript` from `workingDirectory` and returns when it exits.
    public typealias Launch = @Sendable (_ shellScript: String, _ workingDirectory: URL) async throws -> Void

    private let launch: Launch

    public init(launch: @escaping Launch = RunService.runInShell) {
        self.launch = launch
    }

    /// A run lasts as long as its script does; the watchdog only catches a
    /// shell that never exits.
    public static let runInShell: Launch = { shellScript, workingDirectory in
        _ = try await Process.run(
            "/bin/zsh",
            args: ["-c", shellScript],
            cwd: workingDirectory,
            timeout: 365 * 24 * 60 * 60
        )
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
        try await launch(command, worktree.path)
        return try await RunScriptCompletionMonitor.wait(for: location)
    }
}
