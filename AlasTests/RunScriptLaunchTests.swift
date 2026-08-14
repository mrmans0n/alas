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
        #expect(suffix.contains("prepare_transcript()"))
        #expect(suffix.contains("if prepare_transcript; then"))
        #expect(suffix.contains("/usr/bin/script -q \"$transcript\" /usr/bin/env -u SCRIPT /bin/sh -c"))
        #expect(suffix.contains("script -qefc"))
        #expect(suffix.contains("env -u SCRIPT"))
        #expect(suffix.contains("private_umask=$(umask)"))
        #expect(suffix.contains("umask \"$private_umask\""))
        #expect(suffix.contains("transcript_ready=0"))
        #expect(suffix.contains("completion_ready=0"))
        #expect(suffix.contains("code=$?"))
        #expect(suffix.contains(".done.status"))
        #expect(suffix.contains("command -v script"))
        #expect(suffix.contains("find"))
        #expect(suffix.contains("exit_code=$?"))
        #expect(suffix.contains("mv"))
        #expect(suffix.contains("exit \"$exit_code\""))
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
        #expect(try String(contentsOfFile: capture.completion, encoding: .utf8).hasPrefix("42\t"))
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
        let status = dir.appendingPathComponent("status")
        let leaked = dir.appendingPathComponent("leaked")
        #expect(suffix.contains("unset -f prepare_transcript __alas_run_script_capture"))
        let process = try runZsh("\(suffix)\nprintf '%s' \"$?\" > \(AppState.shellQuote(status.path))\n( set | grep -q '^transcript=' || set | grep -q '^completion=' || set | grep -q '^exit_code=' || set | grep -q '^completed_at=' || typeset -f prepare_transcript >/dev/null || typeset -f __alas_run_script_capture >/dev/null ) && printf leaked > \(AppState.shellQuote(leaked.path))\nprintf marker > \(AppState.shellQuote(marker.path))")
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: leaked.path))
        #expect(try String(contentsOf: status, encoding: .utf8) == "42")
        #expect(try String(contentsOfFile: capture.completion, encoding: .utf8).hasPrefix("42\t"))
    }

    @Test func captureSetupFailureStillRunsScript() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("blocked")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
        let capture = RunScriptCapturePaths(
            transcript: blocked.appendingPathComponent("run.log").path,
            completion: blocked.appendingPathComponent("run.done").path
        )
        let scriptURL = dir.appendingPathComponent("exit-42.sh")
        let marker = dir.appendingPathComponent("marker")
        try "#!/bin/sh\nprintf ran > \(AppState.shellQuote(marker.path))\nexit 42\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let suffix = try AppState.runScriptStartupScript(
            script: RunScript(scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL, displayName: "Exit 42", onExit: .close, cwd: nil, isExecutable: true),
            worktreeRoot: dir, branch: "main", projectName: "alas", repoRoot: dir.path, capturePaths: capture
        )

        let process = try runZsh(suffix)

        #expect(process.terminationStatus == 42)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "ran")
    }

    @Test func transcriptSetupFailureStillPublishesCompletion() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("blocked")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)
        let capture = RunScriptCapturePaths(
            transcript: blocked.appendingPathComponent("run.log").path,
            completion: dir.appendingPathComponent("run.done").path
        )
        let scriptURL = dir.appendingPathComponent("exit-42.sh")
        try "#!/bin/sh\nexit 42\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let suffix = try AppState.runScriptStartupScript(
            script: RunScript(scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL, displayName: "Exit 42", onExit: .close, cwd: nil, isExecutable: true),
            worktreeRoot: dir, branch: "main", projectName: "alas", repoRoot: dir.path, capturePaths: capture
        )

        let process = try runZsh(suffix)

        #expect(process.terminationStatus == 42)
        #expect(try String(contentsOfFile: capture.completion, encoding: .utf8).hasPrefix("42\t"))
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
            },
            runScriptCompletionWaiter: { _ in RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false) }
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
    @Test func nonZeroRunCreatesFailureWithSanitizedOutput() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(
                exitCode: 42,
                transcript: Data("bad\u{1B}[31m output\u{1B}[0m\n".utf8),
                truncated: false
            )
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let failures = fixture.state.runScriptFailures(in: fixture.worktree.id)
        #expect(failures.count == 1)
        #expect(failures[0].scriptName == "Dev")
        #expect(failures[0].exitCode == 42)
        #expect(failures[0].branch == "main")
        #expect(failures[0].capturedOutput == .available(text: "bad output\n", truncated: false))
    }

    @MainActor
    @Test func zeroRunCreatesNoFailure() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 0, transcript: Data("ok\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
    }

    @MainActor
    @Test func closeAllTabsPreservesQueuedRunFailures() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        fixture.state.closeAllTabs(worktreeId: fixture.worktree.id)

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
    }

    @MainActor
    @Test func closeAllTabsAllowsCompletedRunMonitorToReportFailure() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .milliseconds(200))
            return RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        fixture.state.closeAllTabs(worktreeId: fixture.worktree.id)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
    }

    @MainActor
    @Test func terminalOpenFailureCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
            },
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                throw NSError(domain: "test", code: 1)
            }
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
    }

    @MainActor
    @Test func alreadyExitedRunScriptTerminalCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func closingRunScriptTerminalCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)

        fixture.state.closeTab(worktreeId: fixture.worktree.id, tabId: tab.id)

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func closingSplitRunScriptPaneCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)
        guard case .terminal(let terminal) = tab else {
            Issue.record("Expected terminal tab")
            return
        }
        let runLeafID = terminal.focusedLeafId
        _ = fixture.state.tabs.splitFocusedLeaf(
            worktreeId: fixture.worktree.id,
            tabId: tab.id,
            axis: .vertical,
            newLeafId: "split",
            newSessionId: "split"
        )
        _ = fixture.state.tabs.setFocusedLeaf(worktreeId: fixture.worktree.id, tabId: tab.id, leafId: runLeafID)

        fixture.state.closeFocusedPane(worktreeId: fixture.worktree.id)

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func closingCompletedKeepOpenRunScriptTerminalPreservesFailure() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .milliseconds(200))
            return RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)

        fixture.state.closeTab(worktreeId: fixture.worktree.id, tabId: tab.id)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
    }

    @MainActor
    @Test func processExitAllowsCompletedMonitorToReportFailure() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .milliseconds(20))
            return RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)
        guard case .terminal(let terminal) = tab else {
            Issue.record("Expected terminal tab")
            return
        }

        fixture.state.closePaneForProcessExit(worktreeId: fixture.worktree.id, leafId: terminal.focusedLeafId)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
    }

    @MainActor
    @Test func processExitDoesNotCancelRemoteMonitorAfterLocalGrace() async throws {
        let state = AppState(store: MemoryStore())
        let runID = UUID().uuidString
        state.runScriptCompletionTasks[runID] = (
            worktreeID: "wt",
            sessionID: "session",
            location: try RunScriptCompletionMonitor.paths(runID: runID, host: "devbox"),
            task: Task {}
        )

        state.cancelRunScriptCompletionTasks(sessionID: "session", after: .milliseconds(1), includeRemote: false)

        try await Task.sleep(for: .milliseconds(20))
        #expect(state.runScriptCompletionTaskCountForTesting == 1)
        state.cancelAllRunScriptCompletionTasks()
    }

    @MainActor
    @Test func processExitEventuallyCancelsRemoteMonitor() async throws {
        let state = AppState(store: MemoryStore())
        let runID = UUID().uuidString
        state.runScriptCompletionTasks[runID] = (
            worktreeID: "wt",
            sessionID: "session",
            location: try RunScriptCompletionMonitor.paths(runID: runID, host: "devbox"),
            task: Task {}
        )

        state.cancelRunScriptCompletionTasks(sessionID: "session", after: .milliseconds(30))

        try await Task.sleep(for: .milliseconds(100))
        #expect(state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func bulkClosingRunScriptTerminalCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let runTab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)
        let otherTab = fixture.state.tabs.appendTerminal(
            worktreeId: fixture.worktree.id,
            title: "Other",
            sessionId: "other"
        )

        fixture.state.closeTabsToLeft(worktreeId: fixture.worktree.id, of: otherTab.id)

        #expect(!fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).contains(where: { $0.id == runTab.id }))
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await Task.sleep(for: .milliseconds(2_200))
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func doubleLaunchCreatesOneMonitor() async throws {
        let waitCount = LockedCounter()
        let fixture = try makeAppStateFixture(waiter: { _ in
            waitCount.increment()
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(waitCount.value == 1)
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

    @MainActor
    private func makeAppStateFixture(
        waiter: @escaping AppState.RunScriptCompletionWaiter,
        terminalSessionOpener: AppState.TerminalSessionOpener? = nil
    ) throws -> (state: AppState, script: RunScript, worktree: Worktree) {
        let dir = try makeTemporaryDirectory()
        let scriptURL = dir.appendingPathComponent("dev.sh")
        try "echo hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        let runScript = RunScript(
            scope: .repo,
            fileName: "dev.sh",
            fileURL: scriptURL,
            displayName: "Dev",
            onExit: .keep,
            cwd: nil,
            isExecutable: false
        )
        let project = ProjectConfig(id: "project", name: "Project", path: dir.path, color: "blue", addedAt: Date())
        let worktree = Worktree(
            id: "wt",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: dir,
            status: .clean,
            lastActivity: Date()
        )
        var openCount = 0
        let opener = terminalSessionOpener ?? { _, _, _, _, _, _, _, _, _ in
            openCount += 1
            return AppState.OpenedTerminalSession(id: "session-\(openCount)", foregroundPid: { nil })
        }
        let state = AppState(
            store: MemoryStore(),
            fileActionErrorHandler: { _, _ in },
            terminalSessionOpener: opener,
            runScriptCompletionWaiter: waiter
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        return (state, runScript, worktree)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
