import Foundation
import Testing
@testable import Alas

/// End-to-end coverage of the Run tab's state: launching, completion versus
/// shell lifetime, worktree isolation, and interrupted execution.
@MainActor
struct AppStateRunRecordTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private struct Fixture {
        let state: AppState
        let script: RunScript
        let worktree: Worktree
        let directory: URL
        var errors: () -> [(title: String, message: String)]
    }

    private func makeFixture(
        waiter: @escaping AppState.RunScriptCompletionWaiter = { _ in
            RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        },
        endpoint: URL? = nil,
        host: String? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-record-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("dev.sh")
        try "echo hi\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        let script = RunScript(
            scope: .repo,
            fileName: "dev.sh",
            fileURL: scriptURL,
            displayName: "Dev",
            onExit: .keep,
            cwd: nil,
            isExecutable: false,
            endpoint: endpoint
        )
        let project = ProjectConfig(
            id: "project",
            name: "Project",
            path: directory.path,
            color: "blue",
            addedAt: Date(),
            host: host
        )
        func worktree(id: String, branch: String) -> Worktree {
            Worktree(
                id: id,
                projectId: project.id,
                name: branch,
                branch: branch,
                path: directory,
                status: .clean,
                lastActivity: Date()
            )
        }
        let errors = ErrorBox()
        var openCount = 0
        let state = AppState(
            store: MemoryStore(),
            fileActionErrorHandler: { title, message in errors.append((title, message)) },
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openCount += 1
                return AppState.OpenedTerminalSession(id: "session-\(openCount)", foregroundPid: { 123 })
            },
            runScriptCompletionWaiter: waiter
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        return Fixture(
            state: state,
            script: script,
            worktree: worktree(id: "wt-1", branch: "main"),
            directory: directory,
            errors: { errors.values }
        )
    }

    private func secondWorktree(_ fixture: Fixture) -> Worktree {
        Worktree(
            id: "wt-2",
            projectId: fixture.worktree.projectId,
            name: "feature",
            branch: "feature",
            path: fixture.directory,
            status: .clean,
            lastActivity: Date()
        )
    }

    private func runRecord(_ fixture: Fixture, worktree: Worktree? = nil) -> RunRecord? {
        fixture.state.runRecords.record(
            worktreeID: (worktree ?? fixture.worktree).id,
            scriptKey: fixture.script.key
        )
    }

    private func scriptTabCount(_ fixture: Fixture, worktree: Worktree? = nil) -> Int {
        fixture.state.tabs.tabs(forWorktree: (worktree ?? fixture.worktree).id).count { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.runScriptKey == fixture.script.key
        }
    }

    // MARK: - Launch and completion

    @Test func successfulRunIsRecordedWithoutClosingItsShell() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        // The row must not sit on "Not run" while the terminal opens.
        #expect(runRecord(fixture)?.status == .starting)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let record = try #require(runRecord(fixture))
        #expect(record.status == .finished(.succeeded))
        #expect(record.finishedAt != nil)
        #expect(record.sessionID == "session-1")
        // An `on-exit: keep` script leaves its shell at a prompt; the command
        // is finished all the same.
        #expect(scriptTabCount(fixture) == 1)
    }

    @Test func failedRunLinksTheCapturedOutput() async throws {
        let fixture = try makeFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 42, transcript: Data("boom\n".utf8), truncated: false)
        })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        let record = try #require(runRecord(fixture))
        #expect(record.status == .finished(.failed(exitCode: 42)))
        let failures = fixture.state.runScriptFailures(in: fixture.worktree.id)
        #expect(failures.count == 1)
        #expect(record.failureID == failures.first?.id)
    }

    @Test func launchFailureRestoresThePreviousObservedOutcome() async throws {
        let fixture = try makeFixture(waiter: { _ in
            RunScriptCompletion(exitCode: 7, transcript: nil, truncated: false)
        })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()
        #expect(runRecord(fixture)?.status == .finished(.failed(exitCode: 7)))

        // Delete the script out from under the next launch.
        try FileManager.default.removeItem(at: fixture.script.fileURL)
        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        #expect(runRecord(fixture)?.status == .finished(.failed(exitCode: 7)))
        #expect(fixture.errors().contains { $0.title == "Run Script Failed" })
    }

    // MARK: - Launch races

    @Test func doubleLaunchProducesOneRunRecord() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        #expect(runRecord(fixture)?.status == .running)
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
    }

    /// A restart supersedes the previous run. When the old monitor finally
    /// reports, it must not overwrite the run that replaced it.
    @Test func supersededMonitorDoesNotOverwriteTheRestartedRun() async throws {
        let calls = LockedCounter()
        let fixture = try makeFixture(waiter: { _ in
            let call = calls.incrementAndGet()
            if call == 1 {
                try await Task.sleep(for: .milliseconds(150))
                return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
            }
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let firstRunID = try #require(runRecord(fixture)?.id)

        fixture.state.restartScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let secondRunID = try #require(runRecord(fixture)?.id)
        #expect(secondRunID != firstRunID)

        // Let the superseded monitor resolve with a success it no longer owns.
        try await Task.sleep(for: .milliseconds(200))

        let current = try #require(runRecord(fixture))
        #expect(current.id == secondRunID)
        #expect(current.status == .running)
    }

    @Test func supersededFailureDoesNotEnqueueCapturedOutput() async throws {
        let calls = LockedCounter()
        let fixture = try makeFixture(waiter: { _ in
            let call = calls.incrementAndGet()
            if call == 1 {
                try await Task.sleep(for: .milliseconds(150))
                return RunScriptCompletion(exitCode: 42, transcript: Data("old failed\n".utf8), truncated: false)
            }
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let firstRunID = try #require(runRecord(fixture)?.id)

        fixture.state.restartScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        let secondRunID = try #require(runRecord(fixture)?.id)
        #expect(secondRunID != firstRunID)

        try await Task.sleep(for: .milliseconds(200))

        let current = try #require(runRecord(fixture))
        #expect(current.id == secondRunID)
        #expect(current.status == .running)
        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
    }

    // MARK: - Stop and interruption

    @Test func stoppingARunReportsStoppedNotFailed() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        fixture.state.stopScript(fixture.script, in: fixture.worktree)

        #expect(runRecord(fixture)?.status == .finished(.stopped))
        #expect(scriptTabCount(fixture) == 0)

        // The monitor teardown that follows a close must not relabel a
        // deliberate stop as a lost process.
        fixture.state.cancelRunScriptCompletionTasks(sessionID: "session-1")
        #expect(runRecord(fixture)?.status == .finished(.stopped))
    }

    @Test func closeAllTabsCancelsPendingLaunchesWithoutPurgingRunHistory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let previous = RunRecord(
            id: UUID().uuidString,
            scriptKey: fixture.script.key,
            scriptName: fixture.script.displayName,
            worktreeID: fixture.worktree.id,
            branch: fixture.worktree.branch,
            target: fixture.state.runExecutionTarget(for: fixture.script, in: fixture.worktree),
            status: .starting,
            startedAt: Date()
        )
        fixture.state.runRecords.begin(previous)
        fixture.state.runRecords.finish(
            runID: previous.id,
            outcome: .succeeded,
            at: Date()
        )
        let launchID = UUID()
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(30))
        }
        fixture.state.pendingScriptLaunches["\(fixture.worktree.id):\(fixture.script.key)"] = PendingRunScriptLaunch(
            id: launchID,
            worktreeID: fixture.worktree.id,
            scriptKey: fixture.script.key
        )
        fixture.state.pendingScriptLaunchTasks[launchID] = task

        fixture.state.closeAllTabs(worktreeId: fixture.worktree.id)

        #expect(fixture.state.pendingScriptLaunches.isEmpty)
        #expect(fixture.state.pendingScriptLaunchTasks.isEmpty)
        #expect(task.isCancelled)
        #expect(runRecord(fixture)?.status == .finished(.succeeded))
    }

    @Test func terminateAllTerminalSessionsCancelsPendingLaunches() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = RunRecord(
            id: UUID().uuidString,
            scriptKey: fixture.script.key,
            scriptName: fixture.script.displayName,
            worktreeID: fixture.worktree.id,
            branch: fixture.worktree.branch,
            target: fixture.state.runExecutionTarget(for: fixture.script, in: fixture.worktree),
            status: .starting,
            startedAt: Date()
        )
        fixture.state.runRecords.begin(record)
        let launchID = UUID()
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(30))
        }
        fixture.state.pendingScriptLaunches["\(fixture.worktree.id):\(fixture.script.key)"] = PendingRunScriptLaunch(
            id: launchID,
            worktreeID: fixture.worktree.id,
            scriptKey: fixture.script.key
        )
        fixture.state.pendingScriptLaunchTasks[launchID] = task

        fixture.state.terminateAllTerminalSessionsAfterConfirmationForTesting()

        #expect(fixture.state.pendingScriptLaunches.isEmpty)
        #expect(fixture.state.pendingScriptLaunchTasks.isEmpty)
        #expect(task.isCancelled)
        #expect(runRecord(fixture)?.status == .finished(.stopped))
    }

    @Test func pendingLaunchCancellationDoesNotParseWorktreeIDFromKey() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let worktreeID = "repo:path:with:colons"
        let record = RunRecord(
            id: UUID().uuidString,
            scriptKey: fixture.script.key,
            scriptName: fixture.script.displayName,
            worktreeID: worktreeID,
            branch: fixture.worktree.branch,
            target: fixture.state.runExecutionTarget(for: fixture.script, in: fixture.worktree),
            status: .starting,
            startedAt: Date()
        )
        fixture.state.runRecords.begin(record)
        let launchID = UUID()
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(30))
        }
        fixture.state.pendingScriptLaunches["\(worktreeID):\(fixture.script.key)"] = PendingRunScriptLaunch(
            id: launchID,
            worktreeID: worktreeID,
            scriptKey: fixture.script.key
        )
        fixture.state.pendingScriptLaunchTasks[launchID] = task

        fixture.state.cancelPendingRunScriptLaunches(worktreeID: worktreeID)

        #expect(task.isCancelled)
        #expect(fixture.state.runRecords.record(worktreeID: worktreeID, scriptKey: fixture.script.key)?.status == .finished(.stopped))
    }

    @Test func pendingLaunchCancellationMatchesExactWorktreeID() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstWorktreeID = "/tmp/repo"
        let secondWorktreeID = "/tmp/repo:staging"
        for worktreeID in [firstWorktreeID, secondWorktreeID] {
            fixture.state.runRecords.begin(RunRecord(
                id: UUID().uuidString,
                scriptKey: fixture.script.key,
                scriptName: fixture.script.displayName,
                worktreeID: worktreeID,
                branch: fixture.worktree.branch,
                target: fixture.state.runExecutionTarget(for: fixture.script, in: fixture.worktree),
                status: .starting,
                startedAt: Date()
            ))
            let launchID = UUID()
            let task = Task<Void, Never> {
                try? await Task.sleep(for: .seconds(30))
            }
            fixture.state.pendingScriptLaunches["\(worktreeID):\(fixture.script.key)"] = PendingRunScriptLaunch(
                id: launchID,
                worktreeID: worktreeID,
                scriptKey: fixture.script.key
            )
            fixture.state.pendingScriptLaunchTasks[launchID] = task
        }

        fixture.state.cancelPendingRunScriptLaunches(worktreeID: firstWorktreeID)

        #expect(fixture.state.pendingScriptLaunches.count == 1)
        #expect(fixture.state.pendingScriptLaunches.values.first?.worktreeID == secondWorktreeID)
        #expect(fixture.state.runRecords.record(worktreeID: firstWorktreeID, scriptKey: fixture.script.key)?.status == .finished(.stopped))
        #expect(fixture.state.runRecords.record(worktreeID: secondWorktreeID, scriptKey: fixture.script.key)?.status == .starting)
        fixture.state.cancelPendingRunScriptLaunches()
    }

    @Test func interruptedRunBecomesUnknownRatherThanSucceeded() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        #expect(runRecord(fixture)?.status == .running)

        // The hosting shell died before the command reported anything.
        fixture.state.cancelRunScriptCompletionTasks(sessionID: "session-1")

        #expect(runRecord(fixture)?.status == .finished(.unknown))
    }

    @Test func waiterFailureBecomesUnknownRatherThanSucceeded() async throws {
        struct DroppedConnection: Error {}
        let fixture = try makeFixture(waiter: { _ in throw DroppedConnection() })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        await fixture.state.waitForRunScriptCompletionTasksForTesting()

        #expect(runRecord(fixture)?.status == .finished(.unknown))
        #expect(fixture.state.runScriptFailures(in: fixture.worktree.id).isEmpty)
    }

    /// Reconnecting to a worktree settles runs whose terminal vanished while
    /// nothing was observing them.
    @Test func reconcileSettlesRunsWhoseTerminalIsGone() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        // A monitor is still watching, so reconciliation must not give up yet.
        fixture.state.reconcileRunRecords(worktreeID: fixture.worktree.id)
        #expect(runRecord(fixture)?.status == .running)

        fixture.state.cancelAllRunScriptCompletionTasks()
        fixture.state.reconcileRunRecords(worktreeID: fixture.worktree.id)
        #expect(runRecord(fixture)?.status == .finished(.unknown))
    }

    // MARK: - Worktree isolation

    @Test func runsAreScopedToTheWorktreeThatLaunchedThem() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let other = secondWorktree(fixture)

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        #expect(runRecord(fixture)?.status == .running)
        #expect(runRecord(fixture, worktree: other) == nil)
        #expect(scriptTabCount(fixture, worktree: other) == 0)

        // Stopping the other worktree's (nonexistent) run must not reach into
        // the running one.
        fixture.state.stopScript(fixture.script, in: other)
        #expect(runRecord(fixture)?.status == .running)
    }

    @Test func eachWorktreeKeepsItsOwnRun() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let other = secondWorktree(fixture)

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        fixture.state.runOrFocusScript(fixture.script, in: other)
        try await Task.sleep(for: .milliseconds(50))

        #expect(runRecord(fixture)?.sessionID == "session-1")
        #expect(runRecord(fixture, worktree: other)?.sessionID == "session-2")

        fixture.state.stopScript(fixture.script, in: fixture.worktree)
        #expect(runRecord(fixture)?.status == .finished(.stopped))
        #expect(runRecord(fixture, worktree: other)?.status == .running)
    }

    // MARK: - Panel independence

    /// The Run panel is a view onto `runRecords`; hiding it or switching the
    /// right pane away must not touch the run.
    @Test func hidingTheRightPaneDoesNotStopARun() async throws {
        let fixture = try makeFixture(waiter: { _ in
            try await Task.sleep(for: .seconds(5))
            return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
        })
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))

        fixture.state.config.rightPaneVisible = false
        fixture.state.rightPaneStore.deactivate()

        #expect(runRecord(fixture)?.status == .running)
        #expect(fixture.state.runScriptCompletionTaskCountForTesting == 1)
        #expect(scriptTabCount(fixture) == 1)
    }

    // MARK: - Endpoints

    @Test func remoteRunRefusesToOpenALoopbackEndpoint() throws {
        let fixture = try makeFixture(
            endpoint: URL(string: "http://localhost:3000")!,
            host: "devbox"
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        fixture.state.openRunEndpoint(fixture.script, in: fixture.worktree)

        let error = try #require(fixture.errors().first)
        #expect(error.title == "Can't Open Endpoint")
        #expect(error.message.contains("devbox"))
        #expect(error.message.contains("http://localhost:3000"))
    }

    @Test func executionTargetReflectsHostAndWorkingDirectory() throws {
        let fixture = try makeFixture(host: "devbox")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let nested = RunScript(
            scope: .repo,
            fileName: "web.sh",
            fileURL: fixture.script.fileURL,
            displayName: "Web",
            onExit: .keep,
            cwd: "apps/web",
            isExecutable: false
        )

        let target = fixture.state.runExecutionTarget(for: nested, in: fixture.worktree)

        #expect(target.host == "devbox")
        #expect(target.workingDirectory == fixture.directory.appendingPathComponent("apps/web").path)
    }

    /// A port already served by another worktree's run is reported, not
    /// resolved by killing anything.
    @Test func portCollisionWithAnotherWorktreeIsReported() async throws {
        let endpoint = URL(string: "http://localhost:3000")!
        let fixture = try makeFixture(
            waiter: { _ in
                try await Task.sleep(for: .seconds(5))
                return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
            },
            endpoint: endpoint
        )
        defer {
            fixture.state.cancelAllRunScriptCompletionTasks()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let other = secondWorktree(fixture)

        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        fixture.state.runOrFocusScript(fixture.script, in: other)
        try await Task.sleep(for: .milliseconds(50))

        #expect(runRecord(fixture, worktree: other)?.portConflict == .ownedByRun(
            worktreeID: fixture.worktree.id,
            branch: "main",
            scriptName: "Dev"
        ))
        // Both runs keep going; a collision is information, not an eviction.
        #expect(runRecord(fixture)?.status == .running)
        #expect(runRecord(fixture, worktree: other)?.status == .running)
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(title: String, message: String)] = []

    var values: [(title: String, message: String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ entry: (title: String, message: String)) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
