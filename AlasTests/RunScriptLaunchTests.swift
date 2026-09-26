import Foundation
import Testing
import UserNotifications
@testable import Alas

struct RunScriptLaunchTests {
    private let capture = RunScriptCapturePaths(
        transcript: "/tmp/alas-runs/run-1.log",
        completion: "/tmp/alas-runs/run-1.done"
    )

    /// Stands in for the production 2 s local run-monitor grace in tests that
    /// exercise it, so they don't wait it out.
    private static let localMonitorGrace: Duration = .milliseconds(200)

    /// How long a "nothing happens within the local grace" test watches
    /// before asserting. Comfortably past `localMonitorGrace` so an expired
    /// grace has had its chance to fire, and far below the 30 s all-monitor
    /// grace so that one never does.
    private static let pastLocalMonitorGrace: Duration = .milliseconds(300)

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
        #expect(suffix.contains("__alas_prepare_run_transcript()"))
        #expect(suffix.contains("if __alas_prepare_run_transcript; then"))
        #expect(suffix.contains("/usr/bin/script -q \"$transcript\" /usr/bin/env -u SCRIPT /bin/sh -c"))
        #expect(suffix.contains("script -qefc"))
        #expect(suffix.contains("env -u SCRIPT"))
        #expect(suffix.contains("private_umask=$(umask)"))
        #expect(suffix.contains("umask \"$private_umask\""))
        #expect(suffix.contains("transcript_ready=0"))
        #expect(suffix.contains("completion_ready=0"))
        #expect(suffix.contains("code=$?"))
        #expect(suffix.contains(".done.status"))
        #expect(suffix.contains("*.snapshot"))
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
        #expect(suffix.contains("unset -f __alas_prepare_run_transcript __alas_run_script_capture"))
        let process = try runZsh("\(suffix)\nprintf '%s' \"$?\" > \(AppState.shellQuote(status.path))\n( set | grep -q '^transcript=' || set | grep -q '^completion=' || set | grep -q '^exit_code=' || set | grep -q '^completed_at=' || set | grep -q '^__alas_' || typeset -f __alas_prepare_run_transcript >/dev/null || typeset -f __alas_run_script_capture >/dev/null || typeset -f __alas_finish_run_script_capture >/dev/null ) && printf leaked > \(AppState.shellQuote(leaked.path))\nprintf marker > \(AppState.shellQuote(marker.path))")
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

    @Test func keepRunExitsWhenCompletionPublicationFails() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let completionDir = dir.appendingPathComponent("completion")
        let capture = RunScriptCapturePaths(
            transcript: dir.appendingPathComponent("run.log").path,
            completion: completionDir.appendingPathComponent("run.done").path
        )
        let scriptURL = dir.appendingPathComponent("exit-42.sh")
        try "#!/bin/sh\nrm -rf \(AppState.shellQuote(completionDir.path))\nexit 42\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let suffix = try AppState.runScriptStartupScript(
            script: RunScript(scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL, displayName: "Exit 42", onExit: .keep, cwd: nil, isExecutable: true),
            worktreeRoot: dir, branch: "main", projectName: "alas", repoRoot: dir.path, capturePaths: capture
        )

        let marker = dir.appendingPathComponent("marker")
        let process = try runZsh("\(suffix)\nprintf marker > \(AppState.shellQuote(marker.path))")

        #expect(process.terminationStatus == 42)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func inheritedErrexitStillPublishesCompletion() throws {
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

        let restored = dir.appendingPathComponent("restored")
        let status = dir.appendingPathComponent("status")
        let process = try runZsh("set -e\n\(suffix)\nprintf '%s' \"$?\" > \(AppState.shellQuote(status.path))\nif typeset -f __alas_restore_run_script_errexit >/dev/null; then __alas_restore_run_script_errexit; fi\ncase $- in *e*) printf restored > \(AppState.shellQuote(restored.path)) ;; esac\nset +e")

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: restored, encoding: .utf8) == "restored")
        #expect(try String(contentsOf: status, encoding: .utf8) == "42")
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

    /// Awaits every in-flight `launchScript` task. When it returns, the
    /// launch has either opened its terminal, registered the completion
    /// monitor, and scheduled any exited-pid cancellation, or failed —
    /// the state a fixed "let it settle" sleep used to approximate.
    @MainActor
    private func finishPendingLaunches(_ state: AppState) async {
        for task in Array(state.pendingScriptLaunchTasks.values) {
            await task.value
        }
    }

    /// Polls `condition` until it holds or `timeout` elapses; the caller
    /// asserts the condition afterwards. The default deadline must stay
    /// below the 5 s the never-completing waiters in this suite sleep:
    /// otherwise a monitor that finished on its own (instead of being
    /// cancelled after the exited-terminal grace) could satisfy a "monitor
    /// count reached 0" wait.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(4),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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

    @Test func capturedCdFailurePublishesCompletion() throws {
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
            script: RunScript(scope: .repo, fileName: scriptURL.lastPathComponent, fileURL: scriptURL, displayName: "Exit 42", onExit: .close, cwd: "missing", isExecutable: true),
            worktreeRoot: dir, branch: "main", projectName: "alas", repoRoot: dir.path, capturePaths: capture
        )

        let process = try runZsh(suffix)

        #expect(process.terminationStatus == 1)
        #expect(try String(contentsOfFile: capture.completion, encoding: .utf8).hasPrefix("1\t"))
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
        await finishPendingLaunches(state)

        #expect(openCount == 1)
        let scriptTabs = state.tabs.tabs(forWorktree: worktree.id).filter { tab in
            if case .terminal(let s) = tab { return s.runScriptKey == runScript.key }
            return false
        }
        #expect(scriptTabs.count == 1)
        #expect(state.pendingScriptLaunches.isEmpty)
    }

    @MainActor
    @Test func cancelledTerminalPreparationDoesNotOpenTerminal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
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

        @MainActor final class Gate {
            var continuation: CheckedContinuation<Void, Never>?

            func wait() async {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                }
            }

            func open() {
                continuation?.resume()
            }
        }

        let gate = Gate()
        let task = Task { @MainActor in
            await gate.wait()
            return try await state.openTerminalTabPreparingRemoteZmxIfNeeded(for: worktree)
        }
        while gate.continuation == nil {
            await Task.yield()
        }
        task.cancel()
        gate.open()

        do {
            _ = try await task.value
            Issue.record("expected terminal launch to be cancelled")
        } catch is CancellationError {
            // Expected: cancellation must be observed before opening a terminal.
        }

        #expect(openCount == 0)
        #expect(state.tabs.tabs(forWorktree: worktree.id).isEmpty)
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
        var notifications: [UNNotificationRequest] = []
        fixture.state.harness.notifications.notificationAdder = { notifications.append($0) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let failures = fixture.state.runScriptFailures(in: fixture.worktree.id)
        #expect(failures.count == 1)
        #expect(failures[0].scriptName == "Dev")
        #expect(failures[0].exitCode == 42)
        #expect(failures[0].branch == "main")
        #expect(notifications.count == 1)
        #expect(notifications[0].content.body == "Failed with exit code 42")
    }

    @MainActor
    @Test(arguments: [false, true])
    func removingQueuedFailureRetiresItsAttention(purge: Bool) async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 65, transcript: Data("compile failed\n".utf8), truncated: false)
        })
        defer { try? FileManager.default.removeItem(at: fixture.worktree.path) }
        fixture.state.harness.notifications.notificationAdder = { _ in }
        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let failure = try #require(fixture.state.runScriptFailures(in: fixture.worktree.id).first)
        let beforeRemoval = fixture.state.attentionAggregation
        #expect(beforeRemoval.unresolvedCount == 1)
        let item = try #require(beforeRemoval.items.first)
        #expect(item.kind == .runScriptFailure)
        #expect(item.jumpTarget == .runScriptFailure(failureID: failure.id))
        #expect(item.presentation == .live)

        if purge {
            fixture.state.cleanupRunScriptState(worktreeID: fixture.worktree.id)
        } else {
            fixture.state.dismissRunScriptFailure(id: failure.id, worktreeID: fixture.worktree.id)
        }

        let afterRemoval = fixture.state.attentionAggregation
        #expect(afterRemoval.unresolvedCount == 0)
        #expect(afterRemoval.items.isEmpty)
        #expect(afterRemoval.history.map(\.eventID) == [item.eventID])
        #expect(afterRemoval.history.first?.presentation == .historical)
        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
    }

    @MainActor
    @Test func zeroRunCreatesNoFailure() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 0, transcript: Data("ok\n".utf8), truncated: false)
        })
        var notifications: [UNNotificationRequest] = []
        fixture.state.harness.notifications.notificationAdder = { notifications.append($0) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
        #expect(fixture.state.attentionStore.events.isEmpty)
        #expect(notifications.count == 1)
        #expect(notifications[0].content.body == "Succeeded")
        let inAppNotifications = fixture.state.inAppNotifications.notifications(in: fixture.worktree.id)
        #expect(inAppNotifications.map(\.message) == ["Dev succeeded"])
        #expect(inAppNotifications.map(\.severity) == [.success])
        #expect(fixture.state.inAppNotifications.notifications(in: "another-worktree").isEmpty)
    }

    @MainActor
    @Test func closeAllTabsPreservesQueuedRunFailures() async throws {
        let fixture = try makeAppStateFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        fixture.state.closeAllTabs(worktreeId: fixture.worktree.id)

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
    }

    @MainActor
    @Test func closeAllTabsAllowsCompletedRunMonitorToReportFailure() async throws {
        // The run completes only after the close below, standing in for a
        // monitor that is still in flight when its terminal goes away.
        let gate = CompletionGate()
        let fixture = try makeAppStateFixture(waiter: { _ in
            await gate.wait()
            return RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)

        fixture.state.closeAllTabs(worktreeId: fixture.worktree.id)
        await gate.open()
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
        await finishPendingLaunches(fixture.state)

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
    }

    @MainActor
    @Test func alreadyExitedRunScriptTerminalCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
            },
            localMonitorGrace: Self.localMonitorGrace
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await waitUntil { fixture.state.runScriptCompletionTaskCountForTesting == 0 }
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func closingRunScriptTerminalCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
            },
            localMonitorGrace: Self.localMonitorGrace
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)

        fixture.state.closeTab(worktreeId: fixture.worktree.id, tabId: tab.id)

        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await waitUntil { fixture.state.runScriptCompletionTaskCountForTesting == 0 }
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func closingSplitRunScriptPaneCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
            },
            localMonitorGrace: Self.localMonitorGrace
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
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
        try await waitUntil { fixture.state.runScriptCompletionTaskCountForTesting == 0 }
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func closingSplitRunScriptPanePreservesRemoteMonitorAfterLocalGrace() async throws {
        let state = AppState(store: MemoryStore(), runScriptLocalMonitorGrace: Self.localMonitorGrace)
        let project = ProjectConfig(id: "project", name: "Project", path: "/repo", color: "blue", addedAt: Date())
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
        let tab = state.tabs.appendTerminal(worktreeId: worktree.id, title: "Run", sessionId: "session")
        _ = state.tabs.splitFocusedLeaf(
            worktreeId: worktree.id,
            tabId: tab.id,
            axis: .vertical,
            newLeafId: "other",
            newSessionId: "other"
        )
        _ = state.tabs.setFocusedLeaf(worktreeId: worktree.id, tabId: tab.id, leafId: "session")

        let runID = UUID().uuidString
        state.runScriptCompletionTasks[runID] = (
            worktreeID: worktree.id,
            sessionID: "session",
            location: try RunScriptCompletionMonitor.paths(runID: runID, host: "devbox"),
            task: Task {}
        )

        state.closeFocusedPane(worktreeId: worktree.id)

        try await Task.sleep(for: Self.pastLocalMonitorGrace)
        #expect(state.runScriptCompletionTaskCountForTesting == 1)
        state.cancelAllRunScriptCompletionTasks()
    }

    @MainActor
    @Test func closingCompletedKeepOpenRunScriptTerminalPreservesFailure() async throws {
        // The run completes only after the close below, standing in for a
        // monitor that is still in flight when its terminal goes away.
        let gate = CompletionGate()
        let fixture = try makeAppStateFixture(waiter: { _ in
            await gate.wait()
            return RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        })

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)

        fixture.state.closeTab(worktreeId: fixture.worktree.id, tabId: tab.id)
        await gate.open()
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
    }

    @MainActor
    @Test func processExitAllowsCompletedMonitorToReportFailure() async throws {
        // Completes only after the local grace has expired: a process exit
        // must not apply that grace to a monitor that is about to report.
        let fixture = try makeAppStateFixture(waiter: { _ in
            try await Task.sleep(for: Self.pastLocalMonitorGrace)
            return RunScriptCompletion(exitCode: 42, transcript: Data("bad\n".utf8), truncated: false)
        }, terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
            .init(id: "session", foregroundPid: { 1 })
        }, localMonitorGrace: Self.localMonitorGrace)
        var notifications: [UNNotificationRequest] = []
        fixture.state.harness.notifications.notificationAdder = { notifications.append($0) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        let tab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)
        guard case .terminal(let terminal) = tab else {
            Issue.record("Expected terminal tab")
            return
        }

        fixture.state.closePaneForProcessExit(worktreeId: fixture.worktree.id, leafId: terminal.focusedLeafId)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).count == 1)
        #expect(notifications.count == 1)
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

        try await waitUntil { state.runScriptCompletionTaskCountForTesting == 0 }
        #expect(state.runScriptCompletionTaskCountForTesting == 0)
    }

    @MainActor
    @Test func cancelAllRunScriptMonitorsCleansLocalCaptureFiles() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = RunScriptCapturePaths(
            transcript: dir.appendingPathComponent("run.log").path,
            completion: dir.appendingPathComponent("run.done").path
        )
        for path in [paths.transcript, paths.completion, "\(paths.completion).tmp", "\(paths.completion).status"] {
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        }
        let state = AppState(store: MemoryStore())
        let runID = UUID().uuidString
        state.runScriptCompletionTasks[runID] = (
            worktreeID: "wt",
            sessionID: "session",
            location: .local(paths: paths),
            task: Task {}
        )

        state.cancelAllRunScriptCompletionTasks()

        #expect(state.runScriptCompletionTaskCountForTesting == 0)
        #expect(!FileManager.default.fileExists(atPath: paths.transcript))
        #expect(!FileManager.default.fileExists(atPath: paths.completion))
        #expect(!FileManager.default.fileExists(atPath: "\(paths.completion).tmp"))
        #expect(!FileManager.default.fileExists(atPath: "\(paths.completion).status"))
    }

    @MainActor
    @Test func transientMissingPidDoesNotCancelRunMonitor() async throws {
        var pidChecks = 0
        let fixture = try makeAppStateFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
            },
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                AppState.OpenedTerminalSession(id: "session", foregroundPid: {
                    pidChecks += 1
                    return pidChecks == 1 ? nil : 123
                })
            },
            localMonitorGrace: Self.localMonitorGrace
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await Task.sleep(for: Self.pastLocalMonitorGrace)
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        fixture.state.cancelAllRunScriptCompletionTasks()
    }

    @MainActor
    @Test func bulkClosingRunScriptTerminalCancelsRunMonitor() async throws {
        let fixture = try makeAppStateFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 1, transcript: nil, truncated: false)
            },
            localMonitorGrace: Self.localMonitorGrace
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)
        let runTab = try #require(fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).first)
        let otherTab = fixture.state.tabs.appendTerminal(
            worktreeId: fixture.worktree.id,
            title: "Other",
            sessionId: "other"
        )

        fixture.state.closeTabsToLeft(worktreeId: fixture.worktree.id, of: otherTab.id)

        #expect(!fixture.state.tabs.tabs(forWorktree: fixture.worktree.id).contains(where: { $0.id == runTab.id }))
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        try await waitUntil { fixture.state.runScriptCompletionTaskCountForTesting == 0 }
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
        await finishPendingLaunches(fixture.state)
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(waitCount.value == 1)
    }

    @MainActor
    @Test func runScriptLaunchIncludesUserStartupScript() async throws {
        var includeUserStartupScript: Bool?
        let fixture = try makeAppStateFixture(
            waiter: { _ in RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false) },
            terminalSessionOpener: { _, _, _, _, _, _, includeUserStartupScriptValue, _, _ in
                includeUserStartupScript = includeUserStartupScriptValue
                return AppState.OpenedTerminalSession(id: "session", foregroundPid: { nil })
            }
        )

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        await finishPendingLaunches(fixture.state)

        #expect(includeUserStartupScript == true)
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
        terminalSessionOpener: AppState.TerminalSessionOpener? = nil,
        localMonitorGrace: Duration = .seconds(2)
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
            runScriptCompletionWaiter: waiter,
            runScriptLocalMonitorGrace: localMonitorGrace,
            attentionStore: AttentionStore(url: dir.appendingPathComponent("attention-events.json"))
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        return (state, runScript, worktree)
    }
}

/// Holds a completion waiter until the test opens it.
private actor CompletionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
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
