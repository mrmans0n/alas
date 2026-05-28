import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct AppStateKeepSessionsAliveTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-keepalive-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    /// On relaunch with `keepSessionsAlive = false`, a persisted terminal
    /// tab whose leaves have no live session must be pruned instead of
    /// resurrected with a fresh plain shell. Otherwise the toggle only
    /// strips the `zmx attach` wrapper while still reopening shells in the
    /// same tab slot on every relaunch.
    @Test func restoreDropsPersistedTerminalTabWhenKeepAliveFalse() async throws {
        let repo = try await makeRepo(name: "drop")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id
        state.config.terminal.keepSessionsAlive = false

        // Simulate a persisted terminal tab whose underlying session is
        // gone (post-relaunch — registry is empty for this leaf id).
        let tab = state.tabs.appendTerminal(
            worktreeId: trees[0].id, title: "main", sessionId: "leaf-orphan"
        )

        let restored = try state.restoreTerminalTabIfNeeded(
            worktreeId: trees[0].id, tabId: tab.id
        )

        #expect(restored == nil)
        #expect(state.tabs.tabs(forWorktree: trees[0].id).isEmpty)
    }

    /// Same scenario but with the setting on: the persisted tab must be
    /// kept and the standard restore path must run (the open-session call
    /// itself may fail in this test environment without Ghostty.App, but
    /// the tab must NOT be pruned).
    @Test func restoreKeepsPersistedTerminalTabWhenKeepAliveTrue() async throws {
        let repo = try await makeRepo(name: "keep")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id
        state.config.terminal.keepSessionsAlive = true

        let tab = state.tabs.appendTerminal(
            worktreeId: trees[0].id, title: "main", sessionId: "leaf-keep"
        )

        // openSession can throw in this test env (no bundled Ghostty.App).
        // The contract under test is "tab is not pruned", which happens
        // before any openSession call — assert that regardless of throw.
        _ = try? state.restoreTerminalTabIfNeeded(
            worktreeId: trees[0].id, tabId: tab.id
        )

        #expect(state.tabs.tabs(forWorktree: trees[0].id).map(\.id) == [tab.id])
    }
}
