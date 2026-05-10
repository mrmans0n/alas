import Testing
import Foundation
@testable import Alas

// Serialize: each test creates an ephemeral repo and shells out to git.
// Concurrent git invocations on macos-26 CI have produced flaky hangs.
@Suite(.serialized)
@MainActor
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

extension ProjectsManagerTests {
    @Test func hidingAndUnhidingFlipsVisibilityAndArchive() async throws {
        let repo = try await makeRepo(name: "delta")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "delta", color: "#5fb7c4")
        try await mgr.refreshWorktrees(projectId: project.id)
        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let mainPath = trees[0].path

        mgr.setWorktreeHidden(projectId: project.id, path: mainPath, hidden: true)
        #expect(mgr.isWorktreeHidden(projectId: project.id, path: mainPath))
        #expect(mgr.visibleWorktrees(projectId: project.id).isEmpty)
        #expect(mgr.archivedWorktrees(projectId: project.id).count == 1)

        mgr.setWorktreeHidden(projectId: project.id, path: mainPath, hidden: false)
        #expect(!mgr.isWorktreeHidden(projectId: project.id, path: mainPath))
        #expect(mgr.visibleWorktrees(projectId: project.id).count == 1)
        #expect(mgr.archivedWorktrees(projectId: project.id).isEmpty)
    }

    @Test func refreshGarbageCollectsOrphanHiddenPaths() async throws {
        let repo = try await makeRepo(name: "epsilon")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "epsilon", color: "#5fb7c4")
        // Pre-seed a hidden path that doesn't correspond to any live worktree.
        let bogus = URL(fileURLWithPath: "/nonexistent/orphan-worktree")
        mgr.setWorktreeHidden(projectId: project.id, path: bogus, hidden: true)
        #expect(mgr.isWorktreeHidden(projectId: project.id, path: bogus))

        try await mgr.refreshWorktrees(projectId: project.id)

        // Refresh should drop the orphan since git worktree list doesn't include it.
        #expect(!mgr.isWorktreeHidden(projectId: project.id, path: bogus))
    }
}
