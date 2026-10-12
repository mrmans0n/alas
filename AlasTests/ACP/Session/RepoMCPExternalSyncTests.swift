import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("Repo servers in the external adapter sync")
struct RepoMCPExternalSyncTests {
    private func writeConfig(_ json: String, to root: URL) throws {
        let config = root.appendingPathComponent(RepoConfig.relativePath)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: config, options: .atomic)
    }

    @Test("approved repo servers sync into .pi/mcp.json, declined stay off")
    func approvedRepoServersSyncAndDeclinedStayOff() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await Process.git(["init"], cwd: root)
        try writeConfig(
            #"""
            {"version": 1, "mcpServers": [
                {"name": "repo-approved", "transport": {"kind": "http", "url": "https://mcp.example/approved", "headers": []}},
                {"name": "repo-declined", "transport": {"kind": "stdio", "command": "declined", "args": [], "environment": []}}
            ]}
            """#,
            to: root
        )
        let approved = ProjectMCPServer(
            id: "repo:repo-approved", name: "repo-approved",
            transport: .http(url: "https://mcp.example/approved", headers: [])
        )
        let declined = ProjectMCPServer(
            id: "repo:repo-declined", name: "repo-declined",
            transport: .stdio(command: "declined", args: [], environment: [])
        )
        let project = ProjectConfig(
            id: "p1", name: "repo", path: root.path, color: "#5fb7c4",
            addedAt: Date(),
            repoMCPTrust: [
                RepoMCPTrust.hash(for: approved): .approved,
                RepoMCPTrust.hash(for: declined): .declined,
            ]
        )
        let worktree = Worktree(
            id: "wt-1", projectId: project.id, name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )

        let state = AppState(store: TestPersistenceStore(ProjectsFile(projects: [project])))
        let manager = try #require(state.acpManager(for: worktree))
        let provider = try #require(manager.externalMCPStatusProvider)

        let external = try await provider(root.path)
        #expect(external.userServerNames == ["repo-approved"])
        #expect(external.skippedServerStatuses.contains { $0.id == "repo:repo-declined" })
    }

    @Test("external sync ignores repo servers for remote projects")
    func remoteProjectStaysSilent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeConfig(
            #"""
            {"version": 1, "mcpServers": [
                {"name": "repo-approved", "transport": {"kind": "http", "url": "https://mcp.example/approved", "headers": []}}
            ]}
            """#,
            to: root
        )
        var project = ProjectConfig(
            id: "p1", name: "remote", path: root.path, color: "#5fb7c4",
            addedAt: Date(), mcpServers: [
                ProjectMCPServer.stdio(name: "app", command: "mine")
            ]
        )
        project.host = "user@example.com"
        let worktree = Worktree(
            id: "wt-1", projectId: project.id, name: "main", branch: "main",
            path: root, status: .clean, lastActivity: Date()
        )

        let state = AppState(store: TestPersistenceStore(ProjectsFile(projects: [project])))
        let manager = try #require(state.acpManager(for: worktree))
        let provider = try #require(manager.externalMCPStatusProvider)

        let external = await provider(root.path)
        #expect(external.userServerNames == ["app"])
    }
}
