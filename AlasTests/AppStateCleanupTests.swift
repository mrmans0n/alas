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

    @Test func createWorktreeInsertsOptimisticRowImmediately() async throws {
        let repo = try await makeRepo(name: "create-opt")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "create-opt", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-opt")
        let id = state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "opt-b",
            destination: dest,
            runStartup: false,
            openTerminal: false
        )
        #expect(!id.isEmpty)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.contains { $0.id == id })
        #expect(state.projectsManager.operationState(for: id) == .creating)

        try await waitForOperationState(state.projectsManager, id: id, equals: nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
    }

    @Test func createWorktreeRejectsExistingDestination() async throws {
        let repo = try await makeRepo(name: "create-existing-destination")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo,
            displayName: "create-existing-destination",
            color: "#5fb7c4"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let existing = try #require(state.projectsManager.worktrees(projectId: project.id).first)

        let id = state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "existing-path",
            destination: existing.path,
            runStartup: false,
            openTerminal: false
        )

        #expect(id.isEmpty)
        #expect(state.projectsManager.operationState(for: existing.id) == nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).filter { $0.id == existing.id }.count == 1)
    }

    @Test func createWorktreeFailureLeavesFailedRow() async throws {
        let repo = try await makeRepo(name: "create-fail")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "create-fail", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-fail")
        let id = state.createWorktree(
            projectId: project.id,
            base: "missing-base",
            branch: "fail-b",
            destination: dest,
            runStartup: false,
            openTerminal: false
        )

        try await waitForOperationStateMatching(state.projectsManager, id: id) { state in
            if case .createFailed = state { return true }
            return false
        }

        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == id })
        if case .createFailed(let message, _) = state.projectsManager.operationState(for: id) {
            #expect(!message.isEmpty)
        } else {
            Issue.record("Expected createFailed state")
        }
    }

    @Test func createWorktreeRetryAllowsFailedOptimisticDestination() async throws {
        let repo = try await makeRepo(name: "create-retry")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "create-retry", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)

        let dest = repo.appendingPathComponent("wt-retry")
        let failedId = state.createWorktree(
            projectId: project.id,
            base: "missing-base",
            branch: "retry-b",
            destination: dest,
            runStartup: false,
            openTerminal: false
        )
        try await waitForOperationStateMatching(state.projectsManager, id: failedId) { state in
            if case .createFailed = state { return true }
            return false
        }

        let retryId = state.createWorktree(
            projectId: project.id,
            base: "main",
            branch: "retry-b",
            destination: dest,
            runStartup: false,
            openTerminal: false
        )

        #expect(retryId == failedId)
        #expect(state.projectsManager.operationState(for: retryId) == .creating)
        try await waitForOperationState(state.projectsManager, id: retryId, equals: nil)
        #expect(state.projectsManager.worktrees(projectId: project.id).contains { $0.id == retryId })
    }

    @Test func deleteWorktreeMarksDeletingImmediately() async throws {
        let repo = try await makeRepo(name: "delete-mark")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "delete-mark", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        let wt = trees[0]

        state.projectsManager.setOperationState(id: wt.id, state: .deleting)
        #expect(state.projectsManager.operationState(for: wt.id) == .deleting)
    }

    // MARK: - Dirty-worktree force-delete state

    @Test func looksLikeDirtyWorktreeErrorMatchesKnownPatterns() {
        #expect(AppState.forceDeleteReason(for: "Cannot delete a dirty worktree") == .dirty)
        #expect(AppState.forceDeleteReason(for: "fatal: 'foo' contains modified or untracked files") == .dirty)
        #expect(AppState.forceDeleteReason(for: "worktree is dirty and cannot be removed") == .dirty)
        #expect(AppState.forceDeleteReason(for: "fatal: working trees containing submodules cannot be moved or removed") == .containsSubmodules)
        #expect(AppState.forceDeleteReason(for: "fatal: not a git repository") == nil)
        #expect(AppState.forceDeleteReason(for: "") == nil)
    }

    @Test func cancelForceDeleteClearsPendingState() async throws {
        let repo = try await makeRepo(name: "cancel-force")
        defer { try? FileManager.default.removeItem(at: repo) }
        let state = AppState()
        let project = try await state.projectsManager.addProject(path: repo, displayName: "cancel-force", color: "#5fb7c4")
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        let wt = try #require(trees.first)

        state.pendingForceDeleteWorktree = AppState.PendingForceDeleteWorktree(
            id: wt.id,
            branch: wt.branch,
            projectId: wt.projectId,
            repoPath: repo,
            worktreePath: wt.path,
            deleteBranchIfMerged: false,
            removedIndex: 0,
            reason: .dirty
        )
        #expect(state.pendingForceDeleteWorktree != nil)

        state.cancelForceDeletePendingWorktree()
        #expect(state.pendingForceDeleteWorktree == nil)
        #expect(state.projectsManager.operationState(for: wt.id) == nil)
    }

    private func waitForOperationState(
        _ manager: ProjectsManager,
        id: String,
        equals expected: WorktreeOperationState?
    ) async throws {
        try await waitForOperationStateMatching(manager, id: id) { $0 == expected }
    }

    private func waitForOperationStateMatching(
        _ manager: ProjectsManager,
        id: String,
        matches: (WorktreeOperationState?) -> Bool
    ) async throws {
        for _ in 0..<80 {
            if matches(manager.operationState(for: id)) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("Timed out waiting for operation state")
    }
}
