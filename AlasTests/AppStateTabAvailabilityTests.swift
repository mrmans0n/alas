import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateTabAvailabilityTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-availability-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func hasActiveEditorTabFalseWhenNoWorktreeSelected() {
        let state = AppState()
        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseWhenNoActiveTab() async throws {
        let repo = try await makeRepo(name: "no-tab")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        #expect(state.activeTab == nil)
        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabTrueForEditor() async throws {
        let repo = try await makeRepo(name: "editor")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendEditor(worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt")

        #expect(state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForTerminal() async throws {
        let repo = try await makeRepo(name: "terminal")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendTerminal(worktreeId: trees[0].id, title: "main", sessionId: "s1")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForDiff() async throws {
        let repo = try await makeRepo(name: "diff")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendDiff(worktreeId: trees[0].id, title: "a.txt", relativePath: "a.txt")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForCommit() async throws {
        let repo = try await makeRepo(name: "commit")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.appendCommit(worktreeId: trees[0].id, sha: "abc", title: "abc msg")

        #expect(!state.hasActiveEditorTab)
    }

    @Test func hasActiveEditorTabFalseForImagePreview() async throws {
        let repo = try await makeRepo(name: "image")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        _ = state.tabs.openImagePreview(worktreeId: trees[0].id, relativePath: "logo.png")

        #expect(!state.hasActiveEditorTab)
    }
}
