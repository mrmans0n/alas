import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct OpenBinaryRoutingTests {
    private func makeRepo(name: String) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-open-binary-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        return dir
    }

    @Test func openBinaryPreviewReusesExistingTab() {
        let mgr = TabsManager()
        let wid = "wt-1"
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "assets/clip.mp4")
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "assets/clip.mp4")
        let tabs = mgr.tabs(forWorktree: wid)
        let binaryTabs = tabs.filter { if case .binaryPreview = $0 { return true } else { return false } }
        #expect(binaryTabs.count == 1)
    }

    @Test func openBinaryPreviewCreatesNewTabForDifferentPath() {
        let mgr = TabsManager()
        let wid = "wt-1"
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "a/clip.mp4")
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "b/other.zip")
        let tabs = mgr.tabs(forWorktree: wid)
        let binaryTabs = tabs.filter { if case .binaryPreview = $0 { return true } else { return false } }
        #expect(binaryTabs.count == 2)
    }

    @Test func openBinaryPreviewActivatesExistingTab() {
        let mgr = TabsManager()
        let wid = "wt-1"
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "clip.mp4")
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "other.zip")
        _ = mgr.openBinaryPreview(worktreeId: wid, relativePath: "clip.mp4")
        let active = mgr.activeTabId(forWorktree: wid)
        let clipTab = mgr.tabs(forWorktree: wid).first { if case .binaryPreview(let s) = $0 { return s.relativePath == "clip.mp4" } else { return false } }
        #expect(active == clipTab?.id)
    }

    @Test func openFileRoutesKnownBinaryToBinaryPreview() async throws {
        let repo = try await makeRepo(name: "route-binary")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        #expect(trees.count == 1)
        state.selectedWorktreeId = trees[0].id

        state.openFile(relativePath: "clip.mp4", worktreeId: trees[0].id)

        guard case .binaryPreview(let s) = state.activeTab else {
            Issue.record("expected binaryPreview tab, got \(String(describing: state.activeTab))")
            return
        }
        #expect(s.relativePath == "clip.mp4")
    }

    @Test func openFileStillRoutesImagesToImagePreview() async throws {
        let repo = try await makeRepo(name: "route-image")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id

        state.openFile(relativePath: "logo.png", worktreeId: trees[0].id)

        guard case .imagePreview = state.activeTab else {
            Issue.record("expected imagePreview tab")
            return
        }
    }

    @Test func openFileStillRoutesTextToEditor() async throws {
        let repo = try await makeRepo(name: "route-text")
        defer { try? FileManager.default.removeItem(at: repo) }

        let state = AppState()
        let project = try await state.projectsManager.addProject(
            path: repo, displayName: "test", color: "#000000"
        )
        try await state.projectsManager.refreshWorktrees(projectId: project.id)
        let trees = state.projectsManager.worktrees(projectId: project.id)
        state.selectedWorktreeId = trees[0].id

        state.openFile(relativePath: "README.md", worktreeId: trees[0].id)

        guard case .editor = state.activeTab else {
            Issue.record("expected editor tab")
            return
        }
    }
}
