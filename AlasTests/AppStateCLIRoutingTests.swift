import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCLIRoutingTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-appstate-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    private func makeStateWithWorktree(name: String) async throws -> (AppState, ProjectConfig, Worktree) {
        let repo = try await makeRepo(name: name)
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        return (state, project, worktree)
    }

    @Test func makeCLICommandRouterUsesTerminalRegistryAndTabs() async throws {
        let repo = try await makeRepo(name: "router")
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "test", color: "#000000")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let worktree = try #require(state.projectsManager.worktrees(projectId: project.id).first)
        state.selectedWorktreeId = worktree.id

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { sessionId in
            sessionId == "s1" ? worktree.id : nil
        })
        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [file.path]))

        #expect(response == .ok)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 { return editor.relativePath == "a.txt" }
            return false
        })
    }

    @Test func startHarnessCLIRequestUsesRealTerminalRegistry() async throws {
        let (state, project, worktree) = try await makeStateWithWorktree(name: "socket-callback")
        defer {
            state.harness.socketServer.shutdown()
            try? FileManager.default.removeItem(at: worktree.path)
        }
        let file = worktree.path.appendingPathComponent("from-socket.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = AlasGhostty.SurfaceView(testIO: FakeGhosttySurfaceIO())
        let session = TerminalSession(
            id: "s1",
            worktreeId: worktree.id,
            projectId: project.id,
            surface: surface,
            executable: "/bin/zsh",
            args: []
        )
        state.terminal.registry.register(session)
        state.startHarness()

        let handler = try #require(state.harness.socketServer.onCLIRequest)
        let response = await handler(.init(version: 1, command: .open, sessionId: "s1", paths: [file.path]))

        #expect(response == .ok)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 { return editor.relativePath == "from-socket.txt" }
            return false
        })
    }

    @Test func makeCLICommandRouterOpensExternalFileOnOriginatingWorktreeAndSelectsIt() async throws {
        let (state, _, worktree) = try await makeStateWithWorktree(name: "external")
        defer { try? FileManager.default.removeItem(at: worktree.path) }
        let externalDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cli-appstate-external-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: externalDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: externalDir) }
        let externalFile = externalDir.appendingPathComponent("external.txt")
        try "outside\n".write(to: externalFile, atomically: true, encoding: .utf8)
        state.selectedWorktreeId = nil

        let router = state.makeCLICommandRouter(sessionWorktreeLookup: { sessionId in
            sessionId == "s1" ? worktree.id : nil
        })
        let response = router.handle(.init(version: 1, command: .open, sessionId: "s1", paths: [externalFile.path]))

        #expect(response == .ok)
        #expect(state.selectedWorktreeId == worktree.id)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains {
            if case .editor(let editor) = $0 {
                return editor.isExternal
                    && editor.externalAbsolutePath == externalFile.standardizedFileURL.path
                    && editor.relativePath.isEmpty
            }
            return false
        })
    }
}
