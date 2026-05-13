import Testing
import Foundation
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateCleanupTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleanup-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func allWorktreeIdsReturnsIdsAfterRefresh() async throws {
        let repo = try await makeRepo(name: "all-ids")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let ids = state.allWorktreeIds()
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(!ids.isEmpty)
        #expect(ids == Set(trees.map(\.id)))
    }

    @Test func allWorktreeIdsEmptyBeforeRefresh() async throws {
        let repo = try await makeRepo(name: "empty-ids")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        _ = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#5fb7c4"
        )

        let ids = state.allWorktreeIds()
        #expect(ids.isEmpty)
    }

    @Test func cleanupMissingWorktreesClosesTabsForDisappearedWorktree() async throws {
        let repo = try await makeRepo(name: "cleanup-tabs")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "cleanup", color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let wt = trees[0]

        state.tabs.appendTerminal(worktreeId: wt.id, title: "term", sessionId: "s1")
        #expect(state.tabs.tabs(forWorktree: wt.id).count == 1)

        let beforeIds = state.allWorktreeIds()
        #expect(beforeIds.contains(wt.id))

        state.projectsManager.removeProject(id: project.id)
        #expect(state.allWorktreeIds().isEmpty)

        state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.tabs.tabs(forWorktree: wt.id).isEmpty)
    }

    @Test func cleanupMissingWorktreesResetsSelection() async throws {
        let repoA = try await makeRepo(name: "sel-a")
        let repoB = try await makeRepo(name: "sel-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }

        let state = AppState()
        let projectA = try await state.projectsManager.addProject(
            path: repoA, displayName: "projA", color: "#5fb7c4"
        )
        let projectB = try await state.projectsManager.addProject(
            path: repoB, displayName: "projB", color: "#c89d6f"
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectA.id)
        try await state.projectsManager.refreshWorktrees(projectId: projectB.id)

        let treesA = state.projectsManager.worktrees(projectId: projectA.id)
        let treesB = state.projectsManager.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesB.count == 1)

        state.selectedWorktreeId = treesA[0].id
        #expect(state.selectedWorktreeId == treesA[0].id)

        let beforeIds = state.allWorktreeIds()

        state.projectsManager.removeProject(id: projectA.id)
        #expect(!state.allWorktreeIds().contains(treesA[0].id))

        state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.selectedWorktreeId == treesB[0].id)
    }

    @Test func cleanupMissingWorktreesPreservesExistingWorktreeTabs() async throws {
        let repoA = try await makeRepo(name: "keep-a")
        let repoB = try await makeRepo(name: "keep-b")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }

        let state = AppState()
        let projectA = try await state.projectsManager.addProject(
            path: repoA, displayName: "keepA", color: "#5fb7c4"
        )
        let projectB = try await state.projectsManager.addProject(
            path: repoB, displayName: "keepB", color: "#c89d6f"
        )
        try await state.projectsManager.refreshWorktrees(projectId: projectA.id)
        try await state.projectsManager.refreshWorktrees(projectId: projectB.id)

        let treesA = state.projectsManager.worktrees(projectId: projectA.id)
        let treesB = state.projectsManager.worktrees(projectId: projectB.id)
        #expect(treesA.count == 1)
        #expect(treesB.count == 1)

        state.tabs.appendTerminal(worktreeId: treesA[0].id, title: "termA", sessionId: "sA")
        state.tabs.appendTerminal(worktreeId: treesB[0].id, title: "termB", sessionId: "sB")
        #expect(state.tabs.tabs(forWorktree: treesA[0].id).count == 1)
        #expect(state.tabs.tabs(forWorktree: treesB[0].id).count == 1)

        let beforeIds = state.allWorktreeIds()

        state.projectsManager.removeProject(id: projectA.id)

        state.cleanupMissingWorktrees(beforeIds: beforeIds)

        #expect(state.tabs.tabs(forWorktree: treesA[0].id).isEmpty)
        #expect(state.tabs.tabs(forWorktree: treesB[0].id).count == 1)
    }
}
