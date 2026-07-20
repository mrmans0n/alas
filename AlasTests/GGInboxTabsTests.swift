import Testing
import Foundation
@testable import Alas

@MainActor
struct GGInboxTabsTests {
    @Test func openOrFocusGGInboxDedupesById() {
        let worktreeId = "gg-inbox-tabs-dedupe"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openOrFocusGGInbox(worktreeId: worktreeId, projectId: "proj-1", projectName: "Proj One")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)

        _ = mgr.appendTerminal(worktreeId: worktreeId, title: "main", sessionId: "s")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 2)

        let second = mgr.openOrFocusGGInbox(worktreeId: worktreeId, projectId: "proj-1", projectName: "Proj One")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 2)
        #expect(second.id == first.id)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
    }
}
