import Foundation
import Testing
@testable import Alas

@MainActor
struct AlasCoreContextTests {
    /// A `main` branch with one empty commit, built once and copied per test.
    private static let repoTemplate = Task { () throws -> URL in
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-core-template-\(UUID().uuidString)")
            .appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        // Auto-maintenance would race the per-test copy over maintenance.lock.
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "maintenance.auto", "false"],
            ["config", "gc.auto", "0"],
            ["commit", "-q", "--allow-empty", "-m", "init"]
        ] {
            let result = try await Process.git(args, cwd: repo)
            guard result.exitCode == 0 else { throw ProcessError.nonZeroExit(result.exitCode, result.stderr) }
        }
        return repo
    }

    /// The headless core drives a worktree, an agent session in it, and a run
    /// of one of its scripts, with no `AppState` or AppKit involved.
    @Test func drivesWorktreeSessionAndRunWithoutAppState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.copyItem(at: try await Self.repoTemplate.value, to: repo)
        let agent = ACPMockClient()
        agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
        agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-session"}"#.utf8) }
        let projectsFile = root.appendingPathComponent("projects.json")
        let context = try AlasCoreContext(
            loadingFrom: PersistenceStore(),
            projectsFile: projectsFile,
            runHistoryStore: try RunHistoryStore(path: root.appendingPathComponent("history.sqlite").path),
            makeSessionManager: { owner, worktree in
                ACPSessionManager(
                    worktreeId: worktree.id,
                    worktreePath: worktree.path.path,
                    owner: owner,
                    persistence: ACPSessionPersistence(path: root.appendingPathComponent("sessions.sqlite").path),
                    setupEvaluator: { _ in .ready },
                    connectionFactory: { _, _, _ in ACPConnection(client: agent) }
                )
            }
        )

        let project = try await context.addProject(path: repo, displayName: "repo", icon: .default(color: "blue"))
        let saved = try PersistenceStore().readIfExists(ProjectsFile.self, from: projectsFile)
        #expect(saved?.projects.first?.cachedWorktrees.isEmpty == false, "the first refresh's topology is persisted")
        let worktree = try await context.createWorktree(
            projectID: project.id,
            branch: "feature",
            base: "main",
            destination: root.appendingPathComponent("feature")
        )
        let reloaded = try AlasCoreContext(loadingFrom: PersistenceStore(), projectsFile: projectsFile, runHistoryStore: nil)
        _ = try await reloaded.projects.refreshWorktrees(projectId: project.id)
        #expect(reloaded.projects.worktrees(projectId: project.id).map(\.id).contains(worktree.id))

        let sessions = context.sessionManager(for: worktree)
        defer { sessions.shutdownBackgroundTasks() }
        let session = sessions.createSession(agentId: "gemini")
        await sessions.attach(to: session.id, freshlyCreated: true)
        #expect(session.remoteSessionId == "agent-session")

        let scriptURL = root.appendingPathComponent("hello.sh")
        try "echo \"hello from $ALAS_BRANCH\"\nexit 3\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        let script = RunScript(
            scope: .repo,
            fileName: "hello.sh",
            fileURL: scriptURL,
            displayName: "Hello",
            onExit: .close,
            cwd: nil,
            isExecutable: false
        )
        #expect(try await context.runScript(script, in: worktree) == .failed(exitCode: 3))
        let record = try #require(context.runRecords.record(worktreeID: worktree.id, scriptKey: script.key))
        #expect(record.status == .finished(.failed(exitCode: 3)))
        await context.runHistory.flush()
        #expect(context.runHistory.hasReport(worktreeID: worktree.id, runID: record.id))
        let archived = try await context.runHistory.store?.entry(id: record.id)
        guard case let .available(text, _) = archived?.output else {
            Issue.record("the run's output is archived")
            return
        }
        #expect(text.contains("hello from feature"))

        try await context.archiveWorktree(worktree)
        #expect(!context.projects.visibleWorktrees(projectId: project.id).map(\.id).contains(worktree.id))
        #expect(context.sessionManagers[.worktree(worktree.id)] == nil)
        #expect(try await context.runHistory.store?.entry(id: record.id) != nil, "archiving keeps run history")
        try context.unarchiveWorktree(path: worktree.path, projectID: project.id)
        #expect(context.projects.visibleWorktrees(projectId: project.id).map(\.id).contains(worktree.id))
    }

    /// A script that ran but never reported its exit status still ran, so
    /// its run is recorded with an unknown outcome instead of being undone.
    @Test func runThatExecutedWithoutReportingKeepsAnUnknownRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-core-\(UUID().uuidString)")
        let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: Date())
        let worktree = Worktree(
            id: root.path, projectId: "p", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date()
        )
        let script = RunScript(
            scope: .repo, fileName: "noop.sh", fileURL: root.appendingPathComponent("noop.sh"),
            displayName: "Noop", onExit: .close, cwd: nil, isExecutable: false
        )
        let context = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: [project]),
            runs: RunService(launch: { _, _ in 7 }),
            runHistoryStore: nil
        )

        await #expect(throws: RunService.RunError.completionNotPublished(exitCode: 7)) {
            try await context.runScript(script, in: worktree)
        }
        #expect(context.runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status == .finished(.unknown))
    }

    /// A second run of a script that is still running would displace the
    /// first one's record and drop its history, so it is refused.
    @Test func refusesToStartAScriptThatIsAlreadyRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-core-\(UUID().uuidString)")
        let project = ProjectConfig(id: "p", name: "p", path: root.path, color: "blue", addedAt: Date())
        let worktree = Worktree(
            id: root.path, projectId: "p", name: "main", branch: "main", path: root,
            status: .clean, lastActivity: Date()
        )
        let script = RunScript(
            scope: .repo, fileName: "noop.sh", fileURL: root.appendingPathComponent("noop.sh"),
            displayName: "Noop", onExit: .close, cwd: nil, isExecutable: false
        )
        let context = AlasCoreContext(
            projects: ProjectsManager(persistedProjects: [project]),
            runs: RunService(launch: { _, _ in 0 }),
            runHistoryStore: nil
        )
        let running = RunRecord(
            id: "first", scriptKey: script.key, scriptName: "Noop", worktreeID: worktree.id, branch: "main",
            target: RunExecutionTarget(host: nil, workingDirectory: root.path), status: .running, startedAt: Date()
        )
        context.runRecords.begin(running)

        await #expect(throws: RunService.RunError.alreadyRunning) {
            try await context.runScript(script, in: worktree)
        }
        #expect(context.runRecords.record(worktreeID: worktree.id, scriptKey: script.key) == running)
    }
}
