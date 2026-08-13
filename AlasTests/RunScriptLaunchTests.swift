import Foundation
import Testing
@testable import Alas

struct RunScriptLaunchTests {
    private let capture = RunScriptCapturePaths(
        transcript: "/tmp/alas-runs/run-1.log",
        completion: "/tmp/alas-runs/run-1.done"
    )

    private func script(
        executable: Bool,
        onExit: RunScriptOnExit = .keep,
        cwd: String? = nil
    ) -> RunScript {
        RunScript(
            scope: .repo, fileName: "dev server.sh",
            fileURL: URL(fileURLWithPath: "/wt/.alas/scripts/dev server.sh"),
            displayName: "Dev Server", onExit: onExit, cwd: cwd, isExecutable: executable
        )
    }

    // `AppState.shellQuote` only wraps a value in single quotes when it
    // contains characters outside `[A-Za-z0-9_/.@%+=,:-]`; plain paths like
    // "/wt" or "/repo" and bare words like "main"/"alas" are emitted
    // unquoted. Only the script filename (which has a space) gets quoted.
    @Test func executableScriptRunsDirectlyWithEnvAndCd() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.hasPrefix("cd /wt || exit 1\n"))
        #expect(suffix.contains("'/wt/.alas/scripts/dev server.sh'"))
        #expect(suffix.contains("ALAS_WORKTREE_ROOT=/wt"))
        #expect(suffix.contains("ALAS_REPO_ROOT=/repo"))
        #expect(suffix.contains("ALAS_BRANCH=main"))
        #expect(suffix.contains("ALAS_PROJECT_NAME=alas"))
        #expect(!suffix.contains("exit \"$status\""))
    }

    @Test func nonExecutableScriptRunsViaSh() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: false),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.contains("/bin/sh '/wt/.alas/scripts/dev server.sh'"))
    }

    @Test func closeOnExitAppendsExit() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, onExit: .close),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.hasSuffix("exit_code=$?\nexit \"$exit_code\""))
    }

    @Test func capturedRunContainsBothHostRecorderForms() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, onExit: .close),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo", capturePaths: capture
        )
        #expect(suffix.contains("uname -s"))
        #expect(suffix.contains("script -qF"))
        #expect(suffix.contains("script -qefc"))
        #expect(suffix.contains("env -u SCRIPT"))
        #expect(suffix.contains("command -v script"))
        #expect(suffix.contains("exit_code=$?"))
        #expect(suffix.contains("mv"))
        #expect(suffix.hasSuffix("exit \"$exit_code\""))
    }

    @Test func capturedRemoteHomePathsExpandAtRuntime() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, onExit: .close),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo",
            capturePaths: RunScriptCapturePaths(
                transcript: "~/.alas/run-transcripts/run.log",
                completion: "~/.alas/run-transcripts/run.done"
            )
        )
        #expect(suffix.contains("transcript=\"$HOME/.alas/run-transcripts/run.log\""))
        #expect(suffix.contains("completion=\"$HOME/.alas/run-transcripts/run.done\""))
        #expect(!suffix.contains("'~/.alas"))
    }

    @Test func capturedCloseRunRecordsOutputAndCompletion() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = RunScriptCapturePaths(
            transcript: dir.appendingPathComponent("run.log").path,
            completion: dir.appendingPathComponent("run.done").path
        )
        let scriptURL = dir.appendingPathComponent("exit-42.sh")
        try "#!/bin/sh\nprintf 'stdout-line\\n'\nprintf 'stderr-line\\n' >&2\nprintf 'script=%s\\n' \"${SCRIPT-unset}\"\nprintf 'cwd=%s\\n' \"$PWD\"\nprintf 'branch=%s\\n' \"$ALAS_BRANCH\"\nexit 42\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let suffix = try AppState.runScriptStartupScript(
            script: RunScript(scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL, displayName: "Exit 42", onExit: .close, cwd: nil, isExecutable: true),
            worktreeRoot: dir, branch: "main", projectName: "alas", repoRoot: dir.path, capturePaths: capture
        )

        let process = try runZsh(suffix)
        #expect(process.terminationStatus == 42)
        #expect(try String(contentsOfFile: capture.completion, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "42")
        let transcript = try String(contentsOfFile: capture.transcript, encoding: .utf8)
        #expect(transcript.contains("stdout-line"))
        #expect(transcript.contains("stderr-line"))
        #expect(transcript.contains("script=unset"))
        #expect(transcript.contains("cwd=\(dir.path)"))
        #expect(transcript.contains("branch=main"))
    }

    @Test func capturedKeepRunAllowsFollowingCommand() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = RunScriptCapturePaths(
            transcript: dir.appendingPathComponent("run.log").path,
            completion: dir.appendingPathComponent("run.done").path
        )
        let scriptURL = dir.appendingPathComponent("exit-42.sh")
        try "#!/bin/sh\nexit 42\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let suffix = try AppState.runScriptStartupScript(
            script: RunScript(scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL, displayName: "Exit 42", onExit: .keep, cwd: nil, isExecutable: true),
            worktreeRoot: dir, branch: "main", projectName: "alas", repoRoot: dir.path, capturePaths: capture
        )

        let marker = dir.appendingPathComponent("marker")
        let process = try runZsh("\(suffix)\nprintf marker > \(AppState.shellQuote(marker.path))")
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(try String(contentsOfFile: capture.completion, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "42")
    }

    @Test func closeOnExitPreservesScriptStatusInZsh() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("exit-42.sh")
        try "#!/bin/sh\nexit 42\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let run = RunScript(
            scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL,
            displayName: "Exit 42", onExit: .close, cwd: nil, isExecutable: true
        )
        let suffix = try AppState.runScriptStartupScript(
            script: run, worktreeRoot: dir,
            branch: "main", projectName: "alas", repoRoot: dir.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", suffix]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 42)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func runZsh(_ command: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", command]
        try process.run()
        process.waitUntilExit()
        return process
    }

    @Test func cwdJoinsWorktreeRoot() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, cwd: "apps/web"),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        #expect(suffix.hasPrefix("cd /wt/apps/web || exit 1\n"))
    }

    @Test func cdFailureStopsTheRunInsteadOfFallingThrough() throws {
        let suffix = try AppState.runScriptStartupScript(
            script: script(executable: true, cwd: "missing"),
            worktreeRoot: URL(fileURLWithPath: "/wt"),
            branch: "main", projectName: "alas", repoRoot: "/repo"
        )
        let lines = suffix.split(separator: "\n", maxSplits: 1)
        #expect(lines[0] == "cd /wt/missing || exit 1")
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    /// `runOrFocusScript` checks `runningScriptTab` synchronously, but the
    /// tab it looks for is only registered once `launchScript`'s async Task
    /// finishes. Calling it twice back-to-back (no `await` in between,
    /// simulating a double-click or repeated Enter) exercises exactly that
    /// window — without the in-flight guard, both calls would launch.
    @MainActor
    @Test func launchingTwiceBeforeCompletionCreatesOnlyOneTab() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let scriptURL = dir.appendingPathComponent("dev.sh")
        try "echo hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        let runScript = RunScript(
            scope: .repo, fileName: "dev.sh", fileURL: scriptURL,
            displayName: "Dev", onExit: .keep, cwd: nil, isExecutable: false
        )
        let project = ProjectConfig(id: "project", name: "Project", path: dir.path, color: "blue", addedAt: Date())
        let worktree = Worktree(
            id: "wt", projectId: project.id, name: "main", branch: "main",
            path: dir, status: .clean, lastActivity: Date()
        )

        var openCount = 0
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openCount += 1
                return AppState.OpenedTerminalSession(id: "session-\(openCount)", foregroundPid: { nil })
            }
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])

        state.runOrFocusScript(runScript, in: worktree)
        state.runOrFocusScript(runScript, in: worktree)
        try await Task.sleep(for: .milliseconds(50))

        #expect(openCount == 1)
        let scriptTabs = state.tabs.tabs(forWorktree: worktree.id).filter { tab in
            if case .terminal(let s) = tab { return s.runScriptKey == runScript.key }
            return false
        }
        #expect(scriptTabs.count == 1)
        #expect(state.pendingScriptLaunches.isEmpty)
    }

    @MainActor
    @Test func staleRunScriptTabWithoutLiveSessionIsNotRunning() throws {
        let state = AppState(store: MemoryStore())
        let runScript = script(executable: false)
        let project = ProjectConfig(
            id: "project",
            name: "Project",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/repo"),
            status: .clean,
            lastActivity: Date()
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        _ = state.tabs.appendTerminal(
            worktreeId: worktree.id,
            title: runScript.displayName,
            sessionId: "missing-session",
            runScriptKey: runScript.key
        )

        #expect(state.runningScriptTab(for: runScript, in: worktree) == nil)
    }
}
