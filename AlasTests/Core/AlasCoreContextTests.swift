import Foundation
import Testing
@testable import Alas

@MainActor
struct AlasCoreContextTests {
    /// The headless core drives a worktree, an agent session in it, and a run
    /// of one of its scripts, with no `AppState` or AppKit involved.
    @Test func drivesWorktreeSessionAndRunWithoutAppState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-core-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "init"]] {
            let result = try await Process.git(args, cwd: repo)
            #expect(result.exitCode == 0, "\(result.stderr)")
        }
        let agent = ACPMockClient()
        agent.script(method: "initialize") { _ in Data(#"{"protocolVersion":1,"sessionCapabilities":{}}"#.utf8) }
        agent.script(method: "session/new") { _ in Data(#"{"sessionId":"agent-session"}"#.utf8) }
        let projectsFile = root.appendingPathComponent("projects.json")
        let context = try AlasCoreContext(
            loadingFrom: PersistenceStore(),
            projectsFile: projectsFile,
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
        let reloaded = try AlasCoreContext(loadingFrom: PersistenceStore(), projectsFile: projectsFile)
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
        let completion = try await context.runs.run(script, in: worktree, project: project)
        #expect(completion.exitCode == 3)
        #expect(String(decoding: completion.transcript ?? Data(), as: UTF8.self).contains("hello from feature"))
    }
}
