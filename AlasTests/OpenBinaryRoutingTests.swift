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
}