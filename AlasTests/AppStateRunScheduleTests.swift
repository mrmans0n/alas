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

    @Test func scheduledCleanupClaimDoesNotOverwriteAnExistingOperation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(fixture.state.claimScheduledAgentWorktreeForCleanup(fixture.worktree))
        #expect(fixture.state.projectsManager.operationState(for: fixture.worktree)
            == .deleting(projectId: fixture.project.id))

        fixture.state.projectsManager.setOperationState(for: fixture.worktree, state: .creating)
        #expect(!fixture.state.claimScheduledAgentWorktreeForCleanup(fixture.worktree))
        #expect(fixture.state.projectsManager.operationState(for: fixture.worktree) == .creating)
    }

    @Test func scheduledCleanupIdentityMustMatchItsCapturedTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let registration = ScheduledAgentRunRegistration(
            reportID: "report",
            occurrenceID: "occurrence",
            scheduleID: "schedule",
            projectID: fixture.project.id,
            worktreeID: fixture.worktree.id,
            sessionID: "scheduled-session",
            promptID: UUID()
        )
        let report = ScheduledAgentReport(
            id: "report",
            occurrenceID: "occurrence",
            scheduleID: "schedule",
            scheduleName: "Nightly",
            projectID: fixture.project.id,
            projectName: fixture.project.name,
            branch: fixture.worktree.branch,
            baseCommit: "base",
            worktreeID: fixture.worktree.id,
            sessionID: "scheduled-session",
            agentID: "codex",
            request: "Review the repository.",
            startedAt: Date(),
            finishedAt: Date(),
            taskState: .succeeded,
            completion: ScheduledAgentCompletion(
                outcome: .succeeded,
                summary: "Complete.",
                checks: [],
                links: []
            ),
            cleanupRequested: true,
            cleanupState: .pending
        )

        #expect(AppState.scheduledAgentCleanupIdentityIsValid(
            report: report,
            registration: registration,
            project: fixture.project,
            worktree: fixture.worktree
        ))
        let unrelatedRegistration = ScheduledAgentRunRegistration(
            reportID: "another-report",
            occurrenceID: "occurrence",
            scheduleID: "schedule",
            projectID: fixture.project.id,
            worktreeID: fixture.worktree.id,
            sessionID: "scheduled-session",
            promptID: registration.promptID
        )
        #expect(!AppState.scheduledAgentCleanupIdentityIsValid(
            report: report,
            registration: unrelatedRegistration,
            project: fixture.project,
            worktree: fixture.worktree
        ))
        let differentWorktreeRegistration = ScheduledAgentRunRegistration(
            reportID: "report",
            occurrenceID: "occurrence",
            scheduleID: "schedule",
            projectID: fixture.project.id,
            worktreeID: "another-worktree",
            sessionID: "scheduled-session",
            promptID: registration.promptID
        )
        #expect(!AppState.scheduledAgentCleanupIdentityIsValid(
            report: report,
            registration: differentWorktreeRegistration,
            project: fixture.project,
            worktree: fixture.worktree
        ))
    }

    @Test func scheduledCleanupRefusesEveryOtherOpenSession() {
        #expect(AppState.scheduledCleanupHasNoOtherSessions(
            worktreeSessionIDs: ["scheduled"],
            managerSessionIDs: ["scheduled"],
            scheduledSessionID: "scheduled"
        ))
        #expect(!AppState.scheduledCleanupHasNoOtherSessions(
            worktreeSessionIDs: ["scheduled", "terminal"],
            managerSessionIDs: ["scheduled"],
            scheduledSessionID: "scheduled"
        ))
        #expect(!AppState.scheduledCleanupHasNoOtherSessions(
            worktreeSessionIDs: ["scheduled"],
            managerSessionIDs: ["scheduled", "other-acp"],
            scheduledSessionID: "scheduled"
        ))
    }

    /// Lives here because this is the suite the problem was found in, but the
    /// invariant is repo-wide: most `AlasTests` fixtures do not inject
    /// `fileActionErrorHandler`, and its default ends in `NSAlert.runModal`.
    /// In a test host nobody can dismiss that alert, so the main thread blocks
    /// for the rest of the run and the suite stops dead with no failure and no
    /// output — which is what "these suites can't run locally" really was.
    @Test func noAlertCanBlockATestHost() throws {
        // Aborts rather than falling through to the call below, so a broken
        // guard is a reported failure instead of a fresh hang.
        try #require(AppState.isRunningUnitTests)
        let state = AppState(store: MemoryStore())
        state.showFileActionError(title: "Run History Failed", message: "Could not save run history.")
    }

    @Test func scheduledRunReportsTheScriptExitThroughTheManualPath() async throws {
        let fixture = try makeFixture(exitCode: 7)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let report = await fixture.state.runSchedule(schedule(target: .worktree(projectId: "project", worktreeId: "wt-1")))
        await fixture.state.flushRunHistoryPersistence()

        #expect(report.outcome == .failed(exitCode: 7))
        let record = try #require(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh"))
        #expect(record.status == .finished(.failed(exitCode: 7)))
        #expect(record.target.host == nil)
        #expect(fixture.state.runScriptFailures(in: "wt-1").count == 1)
        // A failed run is exactly the one whose report the user opens from
        // the schedule's history, so the firing has to carry its coordinates.
        let reference = try #require(report.runs.first)
        #expect(report.runs.count == 1)
        #expect(reference.runID == record.id)
        #expect(reference.worktreeID == "wt-1")
        #expect(reference.branch == "main")
        #expect(reference.scriptName == "dev")
        let archived = try await fixture.history.entry(id: record.id)
        #expect(archived?.outcome == .failed(exitCode: 7))
        #expect(archived?.output == .available(text: "out\n", truncated: false))
        // Nothing to wait on afterwards: the settlement handler was consumed.
        #expect(fixture.state.runScriptSettlementHandlers.isEmpty)
    }

    @Test func projectTargetResolvesToTheMainWorktreeAndSucceeds() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project"))).outcome
        #expect(outcome == .succeeded)
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.status == .finished(.succeeded))
        #expect(fixture.state.runScriptFailures(in: "wt-1").isEmpty)
    }

    @Test func remoteProjectRunsOnItsHost() async throws {
        let fixture = try makeFixture(host: "devbox")
        // This test covers remote launch routing, not repository-hook I/O.
        fixture.state.repoHookLoader = RepoHookLoader { _, _, _ in .missing }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let outcome = await fixture.state.runSchedule(schedule(target: .allProjects)).outcome
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

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project"), scriptKey: "repo:nope.sh")).outcome
        #expect(outcome == .skipped(reason: "Script repo:nope.sh was not found in main."))
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:nope.sh") == nil)
        #expect(fixture.errors().isEmpty)
    }

    @Test func missingTargetsAreSkipped() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let gone = await fixture.state.runSchedule(schedule(target: .worktree(projectId: "project", worktreeId: "wt-gone"))).outcome
        #expect(gone == .skipped(reason: "The worktree no longer exists in Project."))
        let noProject = await fixture.state.runSchedule(schedule(target: .project(id: "nope"))).outcome
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

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project"))).outcome
        #expect(outcome == .skipped(reason: "dev is already running in main."))
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh")?.id == "manual")
    }

    @Test func launchRefusalBecomesALaunchFailureWithoutAnAlert() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.config.terminal.shell = "/bin/fish"

        let outcome = await fixture.state.runSchedule(schedule(target: .project(id: "project"))).outcome
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

        let report = await fixture.state.runSchedule(schedule(target: .project(id: "project")))

        #expect(report.outcome == .launchFailed("Host is unreachable"))
        // The record was rolled back, so there is no report to open. The
        // history entry must not offer one anyway.
        #expect(report.runs.isEmpty)
        #expect(fixture.errors().isEmpty)
        // The same failure started from the Run tab still alerts.
        fixture.state.runOrFocusScript(fixture.script, in: fixture.worktree)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.errors().contains(where: { $0.title == "Run Script Failed" }))
    }

    /// A schedule's history links runs in worktrees whose Run tab may never
    /// have been opened — a worktree the schedule created itself, most
    /// obviously. After a relaunch nothing has loaded their report ids, so the
    /// links would silently stop being offered unless the tab primes them.
    @Test func historyLinksArePrimedWithoutVisitingTheWorktree() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let report = await fixture.state.runSchedule(schedule(target: .project(id: "project")))
        await fixture.state.flushRunHistoryPersistence()
        #expect(report.outcome == .succeeded)
        let reference = try #require(report.runs.first)
        #expect(try await fixture.history.entry(id: reference.runID) != nil)

        // As after a relaunch: the report exists, but nothing has loaded the
        // ids for its worktree yet.
        fixture.state.durableRunReportIDsByWorktreeID = [:]
        #expect(!fixture.state.hasRunReport(worktreeID: reference.worktreeID, runID: reference.runID))

        await fixture.state.primeScheduleRunReportIDs([reference.worktreeID])
        #expect(fixture.state.hasRunReport(worktreeID: reference.worktreeID, runID: reference.runID))
    }

    /// "Pause <project>" has to stop an all-projects schedule from running in
    /// that project, even though the schedule names no project itself.
    @Test func pausedProjectsAreExcludedFromAnAllProjectsFanOut() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.runScheduler.setProjectPaused(true, projectID: "project")

        let scheduled = await fixture.state.runSchedule(schedule(target: .allProjects)).outcome
        #expect(scheduled == .skipped(reason: "Every project with a main worktree is paused."))
        #expect(fixture.state.runRecords.record(worktreeID: "wt-1", scriptKey: "repo:dev.sh") == nil)

        // Run Now is an explicit instruction, so it still runs.
        let manual = await fixture.state.runSchedule(schedule(target: .allProjects), invocation: .manual).outcome
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

        let run = Task { await fixture.state.runSchedule(schedule(target: .allProjects)).outcome }
        // Both projects must reach "running" even though neither can finish.
        // Wait on both: the targets start as independent tasks, so waiting on
        // only one of them and then asserting the other is a race the suite
        // loses whenever the second one happens to win.
        func isRunning(_ worktreeID: String) -> Bool {
            fixture.state.runRecords.record(worktreeID: worktreeID, scriptKey: "repo:dev.sh")?.status == .running
        }
        let deadline = Date().addingTimeInterval(5)
        while !(isRunning("wt-1") && isRunning("wt-2")), Date() < deadline {
            await Task.yield()
        }
        #expect(isRunning("wt-1"))
        #expect(isRunning("wt-2"))

        await gate.open()
        #expect(await run.value == .succeeded)
    }

    @Test func pausedProjectAlsoSkipsItsOwnTargetedSchedules() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.state.runScheduler.setProjectPaused(true, projectID: "project")

        let byProject = await fixture.state.runSchedule(schedule(target: .project(id: "project"))).outcome
        #expect(byProject == .skipped(reason: "Project is paused."))

        let byWorktree = await fixture.state.runSchedule(
            schedule(target: .worktree(projectId: "project", worktreeId: "wt-1"))
        ).outcome
        #expect(byWorktree == .skipped(reason: "Project is paused."))
    }

    @Test func theClockStartsWhenWorktreesLoad() throws {
        let fixture = try makeFixture()
        defer {
            fixture.state.runScheduler.stop()
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        fixture.state.startRunScheduler()
        #expect(fixture.state.runScheduler.isRunning)
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

        let run = Task { await fixture.state.runSchedule(schedule(target: .project(id: "project"))).outcome }
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
            // Without this the default handler is `NSAlert.runModal`, which in
            // a headless test blocks the main thread forever: the run stops
            // dead at whichever test raised the error, with no failure and no
            // output. Any error here is a real problem, so report it as one.
            fileActionErrorHandler: { title, message in
                Issue.record("Unexpected alert during a composed schedule run: \(title) — \(message)")
            },
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
        // "term-agent" is a custom agent, so it carries no ACP launch spec
        // and stands in for the terminal launch. OMP speaks ACP; its binary
        // points nowhere so the chat session's attach fails at the setup
        // check instead of spawning a real agent.
        state.config.agents.custom = [AgentDefinition(
            id: "term-agent", displayName: "Term Agent", binary: "term-agent", binaryOverride: nil,
            promptModeArgs: [], bypassPermissionsFlag: nil, extraTerminalArgs: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )]
        state.config.agents.builtinState["omp"] = BuiltinAgentState(
            isEnabled: true,
            binaryOverride: repo.appendingPathComponent("missing-omp").path,
            extraTerminalArgs: nil
        )
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
        let (state, project, locations) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        state.selectWorktree(id: main.id)

        var composed = schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(branchTemplate: "sched/{name}-{date}", agentId: "term-agent")
        )
        composed.name = "Morning"
        let report = await state.runSchedule(composed)
        // The archive has to land before the temp repo holding its sqlite
        // file is deleted; unlinking it mid-write fails the write.
        await state.flushRunHistoryPersistence()
        #expect(report.outcome == .succeeded)

        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(created.branch.hasPrefix("sched/morning-"))
        // The history has to point at the run in the worktree the schedule
        // made, not at the origin worktree it was aimed from.
        let reference = try #require(report.runs.first)
        #expect(report.runs.count == 1)
        #expect(reference.worktreeID == created.id)
        #expect(reference.branch == created.branch)
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
        #expect(state.projectsManager.operationState(forWorktreeId: created.id, projectId: project.id) == nil)
        // A background schedule never steals the selection.
        #expect(state.selectedWorktreeId == main.id)
    }

    /// A composed schedule's run lives in the worktree the schedule created,
    /// never the one whose card shows the history. Opening its report has to
    /// move the selection there too: activating a tab under another worktree
    /// leaves the centre pane where it was, so the link would look dead.
    @Test func openingAFiringRunSelectsThatRunsWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        state.selectWorktree(id: main.id)

        let report = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(agentId: "term-agent")
        ))
        await state.flushRunHistoryPersistence()
        #expect(report.outcome == .succeeded)
        let run = try #require(report.runs.first)
        #expect(run.worktreeID != main.id)
        // Firing in the background left the selection alone.
        #expect(state.selectedWorktreeId == main.id)

        state.openScheduleFiringRun(run)

        // Following the link is an explicit request to go there, so it moves.
        #expect(state.selectedWorktreeId == run.worktreeID)
        #expect(state.tabs.tabs(forWorktree: run.worktreeID).contains { tab in
            if case .runReport = tab { return true }
            return false
        })
    }

    /// An all-projects firing can land in a project that lives in another
    /// Space. `RootView` resolves the centre pane through the active Space's
    /// projects, so moving the selection alone would leave it empty.
    @Test func openingAFiringRunSwitchesToItsSpace() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }

        // The project lives in a Space that is not the active one.
        let other = state.spacesManager.addSpace(name: "Nightly", emoji: "🌙")
        state.spacesManager.addProject(project.id, toSpace: other)
        #expect(state.spacesManager.activeSpaceId != other)

        let report = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(agentId: "term-agent")
        ))
        await state.flushRunHistoryPersistence()
        let run = try #require(report.runs.first)

        state.openScheduleFiringRun(run)

        #expect(state.spacesManager.activeSpaceId == other)
        #expect(state.selectedWorktreeId == run.worktreeID)
    }

    /// Archiving clears the report-id cache to empty while deliberately
    /// keeping the rows in the database. Treating empty as "already loaded"
    /// would leave an unarchived worktree's links dead for the session.
    @Test func unarchivingAWorktreeRestoresItsHistoryLinks() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }

        let report = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(agentId: "term-agent")
        ))
        await state.flushRunHistoryPersistence()
        let run = try #require(report.runs.first)

        // Exactly the state archiving leaves behind: the id cache emptied by
        // `cleanupWorktreeState(purgeRunHistory: false)` while the rows stay
        // in the database. Unarchiving restores the worktree but reloads
        // nothing, so priming has to.
        state.durableRunReportIDsByWorktreeID[run.worktreeID] = []
        #expect(!state.canOpenScheduleFiringRun(run))

        await state.primeScheduleRunReportIDs([run.worktreeID])

        #expect(state.canOpenScheduleFiringRun(run))
    }

    /// Archiving a worktree keeps its run history on purpose, so the report
    /// outlives the sidebar entry. The centre pane resolves only visible
    /// worktrees, though, so the link has to stop being offered rather than
    /// select an id that renders nothing.
    @Test func anArchivedWorktreesRunIsNamedButNotOffered() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }

        let report = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: "repo:setup.sh",
            composition: RunScheduleComposition(agentId: "term-agent")
        ))
        await state.flushRunHistoryPersistence()
        let run = try #require(report.runs.first)
        let created = try #require(
            state.projectsManager.worktrees(projectId: project.id).first { $0.id == run.worktreeID }
        )
        #expect(state.canOpenScheduleFiringRun(run))

        state.projectsManager.setWorktreeHidden(projectId: project.id, path: created.path, hidden: true)

        // The report itself is deliberately still there...
        #expect(state.hasRunReport(worktreeID: run.worktreeID, runID: run.runID))
        // ...but nothing can render it, so the row must not pretend otherwise.
        #expect(!state.canOpenScheduleFiringRun(run))
        #expect(state.visibleProjectForWorktree(run.worktreeID) == nil)

        // Unarchiving flips that signal back. The Schedules pane keys its
        // priming task on it, so a worktree restored while the pane stays
        // mounted re-primes instead of keeping dead links until a remount.
        state.projectsManager.setWorktreeHidden(projectId: project.id, path: created.path, hidden: false)
        #expect(state.visibleProjectForWorktree(run.worktreeID)?.id == project.id)
        #expect(state.canOpenScheduleFiringRun(run))
    }

    /// A branch template need not vary per occurrence. A second run of the
    /// same schedule has to get its own worktree rather than failing forever
    /// on the name the first one took.
    @Test func aRepeatingBranchTemplateStillGetsAFreshWorktree() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let composed = schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(branchTemplate: "nightly", agentId: "term-agent")
        )

        #expect(await state.runSchedule(composed).outcome == .succeeded)
        #expect(await state.runSchedule(composed).outcome == .succeeded)
        // The archive has to land before the temp repo holding its sqlite
        // file is deleted; unlinking it mid-write fails the write.
        await state.flushRunHistoryPersistence()

        let created = state.projectsManager.worktrees(projectId: project.id)
            .filter { $0.id != main.id }
            .map(\.branch)
            .sorted()
        #expect(created == ["nightly", "nightly-2"])
    }

    /// Occupancy comes from the host that will run `git worktree add`, not
    /// from this Mac's filesystem. For an SSH project the destination lives
    /// on the remote host, where a local check sees nothing — so every run
    /// after the first would pick the name the previous one took and fail.
    @Test func aTakenDestinationIsSkippedEvenWhenNothingIsOnThisMac() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        // The host holds the first run's worktree while this Mac holds
        // nothing, which is what a local check gets wrong.
        let asked = ProbeBox()
        state.scheduledDestinationExistence = { destination, host in
            asked.append((name: destination.lastPathComponent, host: host))
            return destination.lastPathComponent == "nightly" ? .occupied : .free
        }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(branchTemplate: "nightly", agentId: "term-agent")
        )).outcome

        #expect(outcome == .succeeded)
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(created.branch == "nightly-2")
        #expect(asked.values.map(\.name) == ["nightly", "nightly-2"])
        // Whoever owns the destination is who gets asked about it.
        #expect(asked.values.allSatisfy { $0.host == project.host })
    }

    /// A host that cannot be reached answers neither "free" nor "taken".
    /// Treating that silence as free would claim a path that may already hold
    /// a worktree, so the run stops and says which path it could not check.
    @Test func anUndeterminableDestinationFailsTheRunRatherThanGuessing() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        state.scheduledDestinationExistence = { _, _ in .unknown }
        let posted = NotificationBox()
        state.harness.notifications.notificationAdder = { posted.append($0) }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(branchTemplate: "nightly", agentId: "term-agent")
        )).outcome

        guard case .launchFailed(let message) = outcome else {
            Issue.record("Expected an undeterminable destination to fail the run, got \(outcome)")
            return
        }
        #expect(message.contains("nightly"))
        #expect(state.projectsManager.worktrees(projectId: project.id).allSatisfy { $0.id == main.id })
        // Unattended failures have to reach Notification Center, not just the
        // in-app toast list nobody is looking at.
        #expect(posted.values.map(\.content.title).contains { $0.contains("Nightly") })
    }

    /// Removing a scheduled worktree while keeping its branch — what an
    /// unmerged branch left behind by a failed `git branch -d` looks like —
    /// frees the destination path but not the name. `WorktreeService.add`
    /// checks an existing branch out at its own tip instead of branching from
    /// the base, so reusing it would run the schedule against stale code.
    @Test func aRetainedBranchIsNotReusedByTheNextRun() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let composed = schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(branchTemplate: "nightly", agentId: "term-agent")
        )

        #expect(await state.runSchedule(composed).outcome == .succeeded)
        let first = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(first.branch == "nightly")
        // A run leaves commits behind; the branch keeps them after its
        // worktree goes away.
        _ = try await Process.git(
            ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "stale"],
            cwd: first.path
        )
        let stale = try await Process.git(["rev-parse", "HEAD"], cwd: first.path).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Process.git(["worktree", "remove", "--force", first.path.path], cwd: repo)
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        #expect(try await Process.git(["show-ref", "--verify", "--quiet", "refs/heads/nightly"], cwd: repo).exitCode == 0)

        #expect(await state.runSchedule(composed).outcome == .succeeded)

        let second = try #require(
            state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id && $0.id != first.id }
        )
        #expect(second.branch == "nightly-2")
        let head = try await Process.git(["rev-parse", "HEAD"], cwd: second.path).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head != stale)
    }

    @Test func compositionWithoutAScriptJustLaunchesTheAgent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, locations) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(agentId: "term-agent")
        )).outcome
        // The archive has to land before the temp repo holding its sqlite
        // file is deleted; unlinking it mid-write fails the write.
        await state.flushRunHistoryPersistence()
        #expect(outcome == .succeeded)
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        #expect(state.tabs.tabs(forWorktree: created.id).count == 1)
        #expect(locations.locations.isEmpty)
    }

    /// The prompt is typed into the agent's own terminal once the agent is
    /// up, and submitted only when the schedule says so.
    @Test func compositionTypesThePromptIntoTheAgentTerminal() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let typed = TypedTextBox()
        state.scheduledAgentReadiness = { _ in true }
        state.terminalTextSender = { sessionID, text in
            typed.append(sessionID: sessionID, text: text)
            return true
        }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(agentId: "term-agent", prompt: "Fix the\nbuild.", sendsPromptAutomatically: true)
        )).outcome
        await state.flushRunHistoryPersistence()
        #expect(outcome == .succeeded)
        // One message, then Enter.
        #expect(typed.values.map { $0.text } == ["Fix the build.", "\r"])
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        guard case .terminal(let terminal)? = state.tabs.tabs(forWorktree: created.id).first else {
            Issue.record("Expected the agent's terminal tab on the new worktree")
            return
        }
        #expect(typed.values.map { $0.sessionID } == Array(repeating: terminal.root.firstLeaf().sessionId, count: 2))
    }

    @Test func aPromptNotSentAutomaticallyIsLeftInTheInput() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let typed = TypedTextBox()
        state.scheduledAgentReadiness = { _ in true }
        state.terminalTextSender = { sessionID, text in
            typed.append(sessionID: sessionID, text: text)
            return true
        }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(agentId: "term-agent", prompt: "Fix the build.", sendsPromptAutomatically: false)
        )).outcome
        await state.flushRunHistoryPersistence()
        #expect(outcome == .succeeded)
        #expect(typed.values.map { $0.text } == ["Fix the build."])
    }

    /// An agent that never shows up in its terminal gets no prompt typed at
    /// it: the text would land in the shell instead, and with auto-send it
    /// would run there as a command. The launch itself still counts.
    @Test func aPromptIsNotTypedIntoAShellThatNeverStartedTheAgent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let typed = TypedTextBox()
        state.scheduledAgentReadiness = { _ in false }
        state.terminalTextSender = { sessionID, text in
            typed.append(sessionID: sessionID, text: text)
            return true
        }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(agentId: "term-agent", prompt: "rm -rf everything", sendsPromptAutomatically: true)
        )).outcome
        await state.flushRunHistoryPersistence()
        #expect(outcome == .succeeded)
        #expect(typed.values.isEmpty)
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        // The user was not watching, so the undelivered prompt is reported.
        #expect(state.inAppNotifications.notifications(in: created.id).contains { $0.severity == .error && $0.message.contains("prompt") })
    }

    /// An ACP-capable agent opens a chat session instead of a terminal. The
    /// prompt is queued as the session's first message with its line breaks
    /// intact, and the model is parked for attach; nothing is typed.
    ///
    /// The fixture's agent cannot start (its binary points nowhere), which is
    /// the schedule's business to report: a chat session knows its agent
    /// never came up, where a terminal could only guess.
    @Test func anACPCapableAgentGetsAChatSessionWithTheQueuedPrompt() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["omp"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let typed = TypedTextBox()
        state.scheduledAgentReadiness = { _ in true }
        state.terminalTextSender = { sessionID, text in
            typed.append(sessionID: sessionID, text: text)
            return true
        }
        let posted = NotificationBox()
        state.harness.notifications.notificationAdder = { posted.append($0) }

        let outcome = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(
                agentId: "omp", modelId: "gpt-5", prompt: "Fix the\nbuild.", sendsPromptAutomatically: true
            )
        )).outcome
        await state.flushRunHistoryPersistence()

        #expect(typed.values.isEmpty)
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        let tabs = state.tabs.tabs(forWorktree: created.id)
        guard case .acpSession(let tab)? = tabs.first, tabs.count == 1 else {
            Issue.record("Expected exactly one chat tab on the new worktree, got \(tabs)")
            return
        }
        let manager = try #require(state.acpManager(forWorktreeId: created.id))
        let session = try #require(manager.liveSession(for: tab.sessionId))
        #expect(session.agentId == "omp")
        #expect(session.queue.map { ACPSessionRunner.textPreview(of: $0.blocks) } == ["Fix the\nbuild."])
        #expect(session.composerDraft.isEmpty)
        // Attach never got as far as applying it, so the request is still parked.
        #expect(manager.pendingModel[session.id] == "gpt-5")
        // The worktree is not left retryable: the tab exists and the session
        // itself carries the reason and the queued prompt.
        #expect(state.projectsManager.operationState(forWorktreeId: created.id, projectId: project.id) == nil)
        guard case .launchFailed(let message) = outcome else {
            Issue.record("Expected the agent's failure to start to be reported, got \(outcome)")
            return
        }
        #expect(message.contains("could not start"))
        #expect(state.inAppNotifications.notifications(in: created.id).contains { $0.severity == .error && $0.message.contains("could not start") })
        #expect(posted.values.map(\.content.title).contains { $0.contains("Nightly") && $0.contains("did not run") })
    }

    /// A schedule removed while its ACP-capable agent is launching must not
    /// mutate any prepared session state at all — not just skip the enqueue
    /// and attach, but never create the session, persist a composer draft,
    /// or open a tab, since the worktree may already be gone by the time any
    /// of that would run. Mirrors the terminal path's own `Task.isCancelled`
    /// guards in `deliverScheduledPrompt`, exercised here through the same
    /// `launchWorktreeSurface` entry point a schedule uses, with the
    /// enclosing task cancelled before it runs. Uses `sendsAutomatically:
    /// false` because that path writes straight to the composer draft
    /// before any other guard used to run.
    @Test func aCancelledScheduleNeverTouchesPreparedSessionState() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["omp"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        let prepared = PreparedWorktreeACPPrompt(
            sessionID: "cancelled-session", promptID: UUID(), text: "Do the thing", sendsAutomatically: false
        )

        let task = Task {
            try await state.launchWorktreeSurface(
                .acp(agentId: "omp", preparedPrompt: prepared), worktree: main, project: project
            )
        }
        task.cancel()
        _ = try? await task.value

        let manager = try #require(state.acpManager(forWorktreeId: main.id))
        #expect(manager.liveSession(for: prepared.sessionID) == nil)
        #expect(state.tabs.tabs(forWorktree: main.id).isEmpty)
    }

    @Test func aChatPromptNotSentAutomaticallyIsLeftInTheComposer() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["omp"])
        defer { try? FileManager.default.removeItem(atPath: state.config.worktrees.rootPath) }
        let main = try #require(state.projectsManager.visibleMainWorktree(projectId: project.id))
        state.harness.notifications.notificationAdder = { _ in }

        _ = await state.runSchedule(schedule(
            target: .project(id: project.id),
            scriptKey: nil,
            composition: RunScheduleComposition(agentId: "omp", prompt: "Fix the build.", sendsPromptAutomatically: false)
        ))
        await state.flushRunHistoryPersistence()

        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        guard case .acpSession(let tab)? = state.tabs.tabs(forWorktree: created.id).first else {
            Issue.record("Expected the chat tab on the new worktree")
            return
        }
        let manager = try #require(state.acpManager(forWorktreeId: created.id))
        let session = try #require(manager.liveSession(for: tab.sessionId))
        #expect(session.queue.isEmpty)
        #expect(session.composerDraft == ACPComposerDraft(segments: [.text("Fix the build.")]))
        #expect(manager.pendingModel[session.id] == nil)
    }

    /// The surface is decided by the agent the schedule resolves to, at fire
    /// time: chat for an agent with an ACP adapter, terminal otherwise.
    @Test func launchSurfaceFollowsTheAgentsACPSupport() {
        let composition = RunScheduleComposition(
            agentId: "claude", modelId: "opus", prompt: "Hi\nthere", sendsPromptAutomatically: false
        )
        let promptID = UUID()
        #expect(AppState.scheduledLaunchSurface(agentId: "claude", composition: composition, sessionID: "s", promptID: promptID)
            == .acp(agentId: "claude", preparedPrompt: PreparedWorktreeACPPrompt(
                sessionID: "s", promptID: promptID, text: "Hi\nthere", sendsAutomatically: false, modelID: "opus"
            )))
        #expect(AppState.scheduledLaunchSurface(agentId: "term-agent", composition: composition) == .terminal(agentId: "term-agent"))
        // No prompt still opens the session; there is just nothing to queue.
        guard case .acp(_, let prepared?) = AppState.scheduledLaunchSurface(agentId: "omp", composition: RunScheduleComposition()) else {
            Issue.record("Expected a chat session for an ACP-capable agent")
            return
        }
        #expect(prepared.text.isEmpty)
        #expect(prepared.modelID == nil)
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
            composition: RunScheduleComposition(agentId: "term-agent")
        )).outcome
        // The archive has to land before the temp repo holding its sqlite
        // file is deleted; unlinking it mid-write fails the write.
        await state.flushRunHistoryPersistence()
        #expect(outcome == .launchFailed(AppState.WorktreeAgentStartupError.agentUnavailable.localizedDescription))
        let created = try #require(state.projectsManager.worktrees(projectId: project.id).first { $0.id != main.id })
        // The script still ran in the new worktree; only the agent step failed.
        #expect(state.runRecords.record(worktreeID: created.id, scriptKey: "repo:setup.sh")?.status == .finished(.succeeded))
        guard case .launchFailed(_, _, let surface) = state.projectsManager.operationState(forWorktreeId: created.id, projectId: project.id) else {
            Issue.record("Expected a retryable launchFailed state on the new worktree")
            return
        }
        #expect(surface == .terminal(agentId: "term-agent"))
        #expect(state.inAppNotifications.notifications(in: created.id).contains(where: { $0.severity == .error }))
        // Unattended failures also have to reach Notification Center, not
        // just the in-app toast list nobody is looking at.
        let titles = posted.values.map(\.content.title)
        #expect(titles.contains(where: { $0.contains("Nightly") && $0.contains("did not run") }))
    }

    @Test func failingScriptDoesNotLaunchTheAgent() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let (state, project, _) = try await makeComposedState(repo: repo, installedAgentIDs: ["term-agent"])
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
            composition: RunScheduleComposition(agentId: "term-agent")
        )).outcome
        // The archive has to land before the temp repo holding its sqlite
        // file is deleted; unlinking it mid-write fails the write.
        await state.flushRunHistoryPersistence()
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

/// Everything a scheduled run typed into a terminal, in order.
private final class TypedTextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(sessionID: String, text: String)] = []

    var values: [(sessionID: String, text: String)] {
        lock.withLock { storage }
    }

    func append(sessionID: String, text: String) {
        lock.withLock { storage.append((sessionID, text)) }
    }
}

/// Records every destination the scheduler asked about, and which host it
/// asked.
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(name: String, host: String?)] = []

    var values: [(name: String, host: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: (name: String, host: String?)) {
        lock.lock()
        storage.append(value)
        lock.unlock()
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
