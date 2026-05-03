import Testing
import Foundation
@testable import Alas

struct ProjectsManagerTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pm-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func addProjectAppendsToList() async throws {
        let repo = try await makeRepo(name: "alpha")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "alpha", color: "#5fb7c4")
        #expect(mgr.projects.count == 1)
        #expect(project.name == "alpha")
    }

    @Test func refreshWorktreesPopulatesIt() async throws {
        let repo = try await makeRepo(name: "beta")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "beta", color: "#c89d6f")
        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        #expect(trees.first?.branch == "main")
    }

    @Test func removeProjectStripsItAndItsWorktrees() async throws {
        let repo = try await makeRepo(name: "gamma")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "gamma", color: "#9789c7")
        try await mgr.refreshWorktrees(projectId: project.id)
        mgr.removeProject(id: project.id)
        #expect(mgr.projects.isEmpty)
        #expect(mgr.worktrees(projectId: project.id).isEmpty)
    }
}
