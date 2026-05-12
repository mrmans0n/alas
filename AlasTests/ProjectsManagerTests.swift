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

    @Test func updateProjectUpdatesNameAndColorOnly() {
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let project = ProjectConfig(
            id: "project-1",
            name: "Before",
            path: "/tmp/before",
            color: "#5fb7c4",
            addedAt: addedAt,
            hiddenWorktreePaths: ["/tmp/before/.worktree"]
        )
        let other = ProjectConfig(
            id: "project-2",
            name: "Other",
            path: "/tmp/other",
            color: "#9789c7",
            addedAt: addedAt.addingTimeInterval(1),
            hiddenWorktreePaths: []
        )
        let mgr = ProjectsManager(persistedProjects: [project, other])

        mgr.updateProject(
            id: project.id,
            update: ProjectUpdate(name: "After", color: "#d77b88")
        )

        #expect(mgr.projects[0].id == project.id)
        #expect(mgr.projects[0].name == "After")
        #expect(mgr.projects[0].path == project.path)
        #expect(mgr.projects[0].color == "#d77b88")
        #expect(mgr.projects[0].addedAt == project.addedAt)
        #expect(mgr.projects[0].hiddenWorktreePaths == project.hiddenWorktreePaths)
        #expect(mgr.projects[1] == other)

        mgr.updateProject(
            id: "missing",
            update: ProjectUpdate(name: "Ignored", color: "#7fb978")
        )

        #expect(mgr.projects[0].name == "After")
        #expect(mgr.projects[0].color == "#d77b88")
        #expect(mgr.projects[1] == other)
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

        let gcDropped = try await mgr.refreshWorktrees(projectId: project.id)

        // Refresh should drop the orphan since git worktree list doesn't include it.
        #expect(gcDropped)
        #expect(!mgr.isWorktreeHidden(projectId: project.id, path: bogus))
    }

    @Test func refreshAllPopulatesMultipleProjects() async throws {
        let repoA = try await makeRepo(name: "eta")
        defer { try? FileManager.default.removeItem(at: repoA) }
        let repoB = try await makeRepo(name: "theta")
        defer { try? FileManager.default.removeItem(at: repoB) }

        let mgr = ProjectsManager(persistedProjects: [])
        let projectA = try await mgr.addProject(path: repoA, displayName: "eta", color: "#5fb7c4")
        let projectB = try await mgr.addProject(path: repoB, displayName: "theta", color: "#c89d6f")

        // Verify no worktrees are loaded yet.
        #expect(mgr.worktrees(projectId: projectA.id).isEmpty)
        #expect(mgr.worktrees(projectId: projectB.id).isEmpty)

        let gcDropped = await mgr.refreshAll()

        let treesA = mgr.worktrees(projectId: projectA.id)
        let treesB = mgr.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesA.first?.branch == "main")
        #expect(treesB.count == 1)
        #expect(treesB.first?.branch == "main")
        #expect(!gcDropped)
    }

    @Test func refreshAllReturnsTrueWhenAnyProjectGarbageCollects() async throws {
        let repoA = try await makeRepo(name: "iota")
        defer { try? FileManager.default.removeItem(at: repoA) }
        let repoB = try await makeRepo(name: "kappa")
        defer { try? FileManager.default.removeItem(at: repoB) }

        let mgr = ProjectsManager(persistedProjects: [])
        let projectA = try await mgr.addProject(path: repoA, displayName: "iota", color: "#5fb7c4")
        let projectB = try await mgr.addProject(path: repoB, displayName: "kappa", color: "#c89d6f")

        // Seed an orphan hidden path only on projectA.
        let bogus = URL(fileURLWithPath: "/nonexistent/orphan-worktree")
        mgr.setWorktreeHidden(projectId: projectA.id, path: bogus, hidden: true)

        let gcDropped = await mgr.refreshAll()

        // Should return true because projectA GC'd the orphan.
        #expect(gcDropped)
        #expect(!mgr.isWorktreeHidden(projectId: projectA.id, path: bogus))
        // Both projects should still have their main worktree.
        #expect(mgr.worktrees(projectId: projectA.id).count == 1)
        #expect(mgr.worktrees(projectId: projectB.id).count == 1)
    }

    @Test func refreshWithNoOrphansReturnsFalse() async throws {
        let repo = try await makeRepo(name: "zeta")
        defer { try? FileManager.default.removeItem(at: repo) }
        let mgr = ProjectsManager(persistedProjects: [])
        let project = try await mgr.addProject(path: repo, displayName: "zeta", color: "#5fb7c4")
        let gcDropped = try await mgr.refreshWorktrees(projectId: project.id)
        #expect(!gcDropped)
    }
}
