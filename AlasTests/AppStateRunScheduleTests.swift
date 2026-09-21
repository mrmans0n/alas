import Foundation
import Testing
import UserNotifications
@testable import Alas

/// Scheduled runs go through the manual run-script path: same records, same
/// history, same failure queue, same host routing. These pin that, plus the
/// benign skips and the worktree + agent composition.
@Suite(.serialized)
@MainActor
struct AppStateRunScheduleTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private struct Fixture {
        let state: AppState
        let history: RunHistoryStore
        let project: ProjectConfig
        let worktree: Worktree
        /// The same script the schedules target, for tests that also need to
        /// start it the way the Run tab would.
        let script: RunScript
        let directory: URL
        let locations: LocationBox
        var errors: () -> [(title: String, message: String)]
    }

    private func makeFixture(
        exitCode: Int32 = 0,
        host: String? = nil,
        scriptBody: String = "echo hi\n",
        completionGate: Gate? = nil,
        terminalSessionOpener: AppState.TerminalSessionOpener? = nil
    ) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-schedule-tests-\(UUID().uuidString)", isDirectory: true)
        let scripts = RunScriptStore.repoScriptsDir(worktreeRoot: directory)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try scriptBody.write(to: scripts.appendingPathComponent("dev.sh"), atomically: true, encoding: .utf8)
        let history = try RunHistoryStore(path: directory.appendingPathComponent("run-history.sqlite").path)
        let project = ProjectConfig(
            id: "project",
            name: "Project",
            path: directory.path,
            color: "blue",
            addedAt: Date(),
            host: host
        )
        let worktree = Worktree(
            id: "wt-1",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: directory,
            isMainWorktree: true,
            status: .clean,
            lastActivity: Date()
        )
        let errors = ErrorBox()
        let locations = LocationBox()
        var openCount = 0
        let state = AppState(
            store: MemoryStore(),
            fileActionErrorHandler: { title, message in errors.append((title, message)) },
            terminalSessionOpener: terminalSessionOpener ?? { _, _, _, _, _, _, _, _, _ in
                openCount += 1
                return AppState.OpenedTerminalSession(id: "session-\(openCount)", foregroundPid: { 123 })
            },
            // A remote project would otherwise probe its host over SSH before
            // opening the terminal; the fake opener needs no acceleration.
            remoteAccelerationPreparer: { _ in },
            runScriptCompletionWaiter: { location in
                locations.locations.append(location)
                // A gated fixture keeps the run in flight until the test says
                // otherwise, the way a long-running command would.
                if let completionGate { await completionGate.wait() }
                return RunScriptCompletion(exitCode: exitCode, transcript: Data("out\n".utf8), truncated: false)
            },
            runHistoryStore: history,
            runScheduler: RunScheduler(
                store: MemoryStore(),
                fileURL: directory.appendingPathComponent("run-schedules.json")
            ),
            attentionStore: AttentionStore(url: directory.appendingPathComponent("attention-events.json"))
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        // Remote discovery would go over SSH; either way the schedule only
        // needs the same repo scripts the manual palette would have listed,
        // without the user's real global scripts leaking into the test.
        state.runScheduleScriptDiscovery = { root, _ in
            .scripts(RunScriptStore.scripts(worktreeRoot: root, globalDir: directory.appendingPathComponent("no-globals")))
        }
        let script = RunScript(
            scope: .repo,
            fileName: "dev.sh",
            fileURL: scripts.appendingPathComponent("dev.sh"),
            displayName: "dev",
            onExit: .keep,
            cwd: nil,
            isExecutable: false
        )
        return Fixture(
            state: state,
            history: history,
            project: project,
            worktree: worktree,
            script: script,
            directory: directory,
            locations: locations,
            errors: { errors.values }
        )
    }

    private func schedule(
        target: RunScheduleTarget,
        scriptKey: String? = "repo:dev.sh",
        composition: RunScheduleComposition? = nil
    ) -> RunSchedule {
        RunSchedule(
            id: "sched",
            name: "Nightly",
            target: target,
            scriptKey: scriptKey,
            trigger: .interval(seconds: 3_600),
            composition: composition
        )
    }

    @Test func scheduledRunReportsTheScriptExitThroughTheManualPath() async throws {
        let fixture = try makeFixture(exitCode: 7)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .worktree(projectId: "project", worktreeId: "wt-1")))
        await fixture.state.flushRunHistoryPersistence()

        #expect(outcome == .failed(exitCode: 7))
        let record = try #require(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh"))
        #expect(record.status == .finished(.failed(exitCode: 7)))
        #expect(record.target.host == nil)
        #expect(fixture.state.runScriptFailures(in: "wt-1").count == 1)
        let archived = try await fixture.history.entry(id: record.id)
        #expect(archived?.outcome == .failed(exitCode: 7))
        #expect(archived?.output == .available(text: "out\n", truncated: false))
        // Nothing to wait on afterwards: the settlement handler was consumed.
        #expect(fixture.state.runScriptSettlementHandlers.isEmpty)
    }

    @Test func projectTargetResolvesToTheMainWorktreeAndSucceeds() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project")))
        #expect(outcome == .succeeded)
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.succeeded))
        #expect(fixture.state.runScriptFailures(in: "wt-1").isEmpty)
    }

    @Test func remoteProjectRunsOnItsHost() async throws {
        let fixture = try makeFixture(host: "devbox")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .allProjects))
        #expect(outcome == .succeeded)
        let record = try #require(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh"))
        #expect(record.target.host == "devbox")
        #expect(record.target.workingDirectory == fixture.directory.path)
        guard case .remote(let host, _)? = fixture.locations.locations.first else {
            Issue.record("Expected the completion monitor to watch the remote host")
            return
        }
        #expect(host == "devbox")
    }

    @Test func missingScriptIsSkippedNotFailed() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project"), scriptKey: "repo:nope.sh"))
        #expect(outcome == .skipped(reason: "Script repo:nope.sh was not found in main."))
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:nope.sh") == nil)
        #expect(fixture.errors().isEmpty)
    }

    @Test func missingTargetsAreSkipped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let gone = await fixture.state.runSchedule(schedule(target: .worktree(projectId: "project", worktreeId: "wt-gone")))
        #expect(gone == .skipped(reason: "The worktree no longer exists in Project."))
        let noProject = await fixture.state.runSchedule(schedule(target: .project(id: "nope")))
        #expect(noProject == .skipped(reason: "The project no longer exists."))
    }

    @Test func aRunAlreadyInProgressIsNotStacked() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.runRecords.begin(RunRecord(
            id: "manual",
            scriptKey: "repo:dev.sh",
            scriptName: "dev",
            worktreeID: "wt-1",
            branch: "main",
            target: .init(host: nil, workingDirectory: fixture.directory.path),
            status: .running,
            startedAt: Date()
        ))

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project")))
        #expect(outcome == .skipped(reason: "dev is already running in main."))
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.id == "manual")
    }

    @Test func launchRefusalBecomesALaunchFailureWithoutAnAlert() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.config.terminal.shell = "/bin/fish"

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project")))
        guard case .launchFailed(let message) = outcome else {
            Issue.record("Expected launch failure, got \(outcome)")
            return
        }
        #expect(message.contains("zsh or bash"))
        #expect(fixture.errors().isEmpty)
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh") == nil)
    }

    /// A terminal that fails to open asynchronously — an unreachable SSH host,
    /// say — must not put a modal alert in front of whoever is using the Mac
    /// while a timer fires in the background.
    @Test func asyncLaunchFailureOfAScheduledRunRaisesNoAlert() async throws {
        struct TerminalOpenFailure: LocalizedError {
            var errorDescription: String? { "Host is unreachable" }
        }
        let fixture = try makeFixture(terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
            throw TerminalOpenFailure()
        })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project")))

        #expect(outcome == .launchFailed("Host is unreachable"))
        #expect(fixture.errors().isEmpty)
        // The same failure started from the Run tab still alerts.
        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.errors().contains(where: { $0.title == "Run Script Failed" }))
    }

    /// "Pause <project>" has to stop an all-projects schedule from running in
    /// that project, even though the schedule names no project itself.
    @Test func pausedProjectsAreExcludedFromAnAllProjectsFanOut() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.runScheduler.setProjectPaused(true, projectID: "project")

        let scheduled = await fixture.state.runSchedule(schedule(target: .allProjects))
        #expect(scheduled == .skipped(reason: "Every project with a main worktree is paused."))
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh") == nil)

        // Run Now is an explicit instruction, so it still runs.
        let manual = await fixture.state.runSchedule(schedule(target: .allProjects), invocation: .manual)
        #expect(manual == .succeeded)
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.succeeded))
    }

    /// Run scripts may be servers that never exit. Fanning out must start
    /// every project's run rather than waiting for the first to settle, or a
    /// single long-running script starves every other project forever.
    @Test func aLongRunningTargetDoesNotStarveTheOtherProjects() async throws {
        let gate = Gate()
        let fixture = try makeFixture(completionGate: gate)
        defer {
            Task { await gate.open() }
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        // A second project whose main worktree has the same script.
        let second = ProjectConfig(
            id: "project-2",
            name: "Second",
            path: fixture.directory.path,
            color: "green",
            addedAt: Date()
        )
        fixture.state.projectsManager = ProjectsManager(persistedProjects: [fixture.project, second])
        fixture.state.projectsManager.insertOptimisticWorktree(fixture.worktree)
        fixture.state.projectsManager.insertOptimisticWorktree(Worktree(
            id: "wt-2",
            projectId: second.id,
            name: "main",
            branch: "main",
            path: fixture.directory,
            isMainWorktree: true,
            status: .clean,
            lastActivity: Date()
        ))

        let run = Task { await fixture.state.runSchedule(schedule(target: .allProjects)) }
        // Both projects must reach "running" even though neither can finish.
        let deadline = Date().addingTimeInterval(5)
        while fixture.state.runRecords.record(worktreeID: "wt-2", scriptKey: "repo:dev.sh")?.status != .running,
              Date() < deadline {
            await Task.yield()
        }
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .running)
        #expect(fixture.state.runRecords.record(worktreeID: "wt-2", scriptKey: "repo:dev.sh")?.status == .running)

        await gate.open()
        #expect(await run.value == .succeeded)
    }

    @Test func pausedProjectAlsoSkipsItsOwnTargetedSchedules() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.runScheduler.setProjectPaused(true, projectID: "project")

        let byProject = await fixture.state.runSchedule(schedule(target: .project(id: "project")))
        #expect(byProject == .skipped(reason: "Project is paused."))

        let byWorktree = await fixture.state.runSchedule(
            schedule(target: .worktree(projectId: "project", worktreeId: "wt-1"))
        )
        #expect(byWorktree == .skipped(reason: "Project is paused."))
    }

    /// The preview flag owns the clock: with it off nothing is evaluated, so
    /// no schedule can fire however many are saved.
    @Test func theClockRunsOnlyWhileThePreviewFlagIsOn() throws {
        let fixture = try makeFixture()
        defer {
            fixture.state.runScheduler.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture.state.config.schedulesEnabled = false

        fixture.state.startRunSchedulerIfEnabled()
        #expect(!fixture.state.runScheduler.isRunning)

        fixture.state.setSchedulesEnabled(true)
        #expect(fixture.state.config.schedulesEnabled)
        #expect(fixture.state.runScheduler.isRunning)

        fixture.state.setSchedulesEnabled(false)
        #expect(!fixture.state.runScheduler.isRunning)
    }

    /// Deleting the worktree under an in-flight scheduled run discards its
    /// record without ever finishing it. The run must still settle, otherwise
    /// the schedule would wait forever and never fire again.
    @Test func tearingDownTheWorktreeSettlesAnInFlightScheduledRun() async throws {
        let gate = Gate()
        let fixture = try makeFixture(completionGate: gate)
        defer {
            Task { await gate.open() }
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        let run = Task { await fixture.state.runSchedule(schedule(target: .project(id: "project"))) }
        // Tear down only once the command is actually running: that is the
        // path where the worktree's runs are purged rather than finished.
        let deadline = Date().addingTimeInterval(5)
        while fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status != .running,
              Date() < deadline {
            await Task.yield()
        }
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .running)
        #expect(!fixture.state.runScriptSettlementHandlers.isEmpty)

        fixture.state.cleanupRunScriptState(worktreeID: "wt-1")

        let outcome = await run.value
        #expect(outcome == .unknown)
        #expect(fixture.state.runScriptSettlementHandlers.isEmpty)
    }

    // MARK: - Composition

    private func makeRepo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-schedule-compose-\(UUID().uuidString)", isDirectory: true)
        let scripts = RunScriptStore.repoScriptsDir(worktreeRoot: dir)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try "echo setup\n".write(to: scripts.appendingPathComponent("setup.sh"), atomically: true, encoding: .utf8)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["add", "."], cwd: dir)
        _ = try await Process.git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"], cwd: dir)
        return dir
    }

    private func makeComposedState(
        repo: URL,
        installedAgentIDs: Set<String>
    ) async throws -> (AppState, ProjectConfig, LocationBox) {
        let locations = LocationBox()
        var openCount = 0
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openCount += 1
                return AppState.OpenedTerminalSession(id: "session-\(openCount)", foregroundPid: { 123 })
            },
            runScriptCompletionWaiter: { location in
                locations.locations.append(location)
                return RunScriptCompletion(exitCode: 0, transcript: nil, truncated: false)
            },
            runHistoryStore: try RunHistoryStore(path: repo.appendingPathComponent("history.sqlite").path),
            runScheduler: RunScheduler(store: MemoryStore(), fileURL: repo.appendingPathComponent("schedules.json")),
            attentionStore: AttentionStore(url: repo.appendingPathComponent("attention-events.json"))
        )
        state.config.worktrees.rootPath = repo.deletingLastPathComponent().appendingPathComponent("wts-\(UUID().uuidString)").path
        state.config.worktrees.pathTemplate = "{worktreeRoot}/{repo}/{branch}"
        state.config.agents.builtinState["claude"] = BuiltinAgentState(isEnabled: true, binaryOverride: nil, extraTerminalArgs: nil)
        state.agentRegistry = AgentRegistry(
            builtinState: state.config.agents.builtinState,
            customs: state.config.agents.custom,
            installedIds: installedAgentIDs
        )
        state.runScheduleScriptDiscovery = { root, _ in
            .scripts(RunScriptStore.scripts(worktreeRoot: root, globalDir: repo.appendingPathComponent("no-globals")))
        }
        let project = try await state.projectsManager.addProject(path: repo, displayName: "compose", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        return (state, project, locations)
    }

    @Test func compositionCreatesAWorktreeRunsTheScriptThereAndLaunchesTheAgent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, locations) = try await makeComposedState(repo: repo, installedAgentIDs: ["claude"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        state.selectWorktree(id: main.id)

        var composed = schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(branchTemplate: "sched/{name}-{date}", agentId: "claude")
        )
        composed.name = "Morning"
        let outcome = await state.runSchedule(composed)
        #expect(outcome == .succeeded)

        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(created.branch.hasPrefix("sched/morning-"))
        // The script and its record belong to the new worktree, not main.
        let record = try #require(state.runRecords.record(worktreeID: created.id, scriptKey: "repo:setup.sh"))
        #expect(record.status == .finished(.succeeded))
        #expect(record.target.workingDirectory == created.path.path)
        #expect(state.runRecords.record(worktreeID: main.id, scriptKey: "repo:setup.sh") == nil)
        #expect(locations.locations.count == 1)
        // Script terminal + agent terminal, both attributed to the new worktree.
        let terminals = state.tabs.tabs(forWorktree: created.id).filter {
            if case .terminal = $0 { return true }
            return false
        }
        #expect(terminals.count == 2)
        #expect(state.tabs.tabs(forWorktree: main.id).isEmpty)
        #expect(state.projectsManager.operationState(for: created.id) == nil)
        // A background schedule never steals the selection.
        #expect(state.selectedWorktreeId == main.id)
    }

    /// A branch template need not vary per occurrence. A second run of the
    /// same schedule has to get its own worktree rather than failing forever
    /// on the name the first one took.
    @Test func aRepeatingBranchTemplateStillGetsAFreshWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["claude"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let composed = schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(branchTemplate: "nightly", agentId: "claude")
        )

        #expect(await state.runSchedule(composed) == .succeeded)
        #expect(await state.runSchedule(composed) == .succeeded)

        let created = state.projectsManager.worktrees(projectId: project.id)
            .filter { $0.id != main.id }
            .map(\.branch)
            .sorted()
        #expect(created == ["nightly", "nightly-2"])
    }

    @Test func compositionWithoutAScriptJustLaunchesTheAgent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, locations) = try await makeComposedState(repo: repo, installedAgentIDs: ["claude"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(agentId: "claude")
        ))
        #expect(outcome == .succeeded)
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(state.tabs.tabs(forWorktree: created.id).count == 1)
        #expect(locations.locations.isEmpty)
    }

    @Test func unavailableAgentLeavesTheWorktreeRetryableAndReportsLaunchFailure() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: [])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let posted = NotificationBox()
        state.harness.notifications.notificationAdder = { posted.append($0) }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(agentId: "claude")
        ))
        #expect(outcome == .launchFailed(AppState.WorktreeAgentStartupError.agentUnavailable.localizedDescription))
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        // The script still ran in the new worktree; only the agent step failed.
        #expect(state.runRecords.record(worktreeID: created.id, scriptKey: "repo:setup.sh")?.status == .finished(.succeeded))
        guard case .launchFailed(_, _, let surface) = state.projectsManager.operationState(for: created.id) else {
            Issue.record("Expected a retryable launchFailed state on the new worktree")
            return
        }
        #expect(surface == .terminal(agentId: "claude"))
        #expect(state.inAppNotifications.notifications(in: created.id).contains(where: { $0.severity == .error }))
        // Unattended failures also have to reach Notification Center, not
        // just the in-app toast list nobody is looking at.
        let titles = posted.values.map(\.content.title)
        #expect(titles.contains(where: { $0.contains("Nightly") && $0.contains("did not run") }))
    }

    @Test func failingScriptDoesNotLaunchTheAgent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["claude"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        // The fixture's waiter always reports exit 0, so the script step is
        // made to fail at launch instead: an unsupported shell refuses it.
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        state.config.terminal.shell = "/bin/fish"
        // Keep the failure notification away from the real notification
        // centre; no test should post to the user's Notification Center.
        let posted = NotificationBox()
        state.harness.notifications.notificationAdder = { posted.append($0) }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(agentId: "claude")
        ))
        guard case .launchFailed = outcome else {
            Issue.record("Expected the script refusal to surface, got \(outcome)")
            return
        }
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(state.tabs.tabs(forWorktree: created.id).isEmpty)
    }
}

// Helpers live at file scope: a global actor attribute on the suite would
// otherwise propagate into nested types, which an `actor` cannot accept.

private final class LocationBox: @unchecked Sendable {
    var locations: [RunScriptCaptureLocation] = []
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
        defer { lock.unlock() }
        storage.append(entry)
    }
}

private final class NotificationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [UNNotificationRequest] = []

    var values: [UNNotificationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: UNNotificationRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }
}

/// Holds a fake run open until the test lets it finish.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
