import Testing
import Foundation
@testable import Alas

struct TabsManagerTests {
    @Test func newTerminalAppendsAndActivates() {
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: "w")) }
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "w", title: "main", sessionId: "s")
        #expect(mgr.tabs(forWorktree: "w").count == 1)
        #expect(mgr.activeTabId(forWorktree: "w") == tab.id)
    }

    @Test func closingActivatesNeighbour() {
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: "w")) }
        let mgr = TabsManager()
        let t1 = mgr.appendTerminal(worktreeId: "w", title: "a", sessionId: "s1")
        let t2 = mgr.appendTerminal(worktreeId: "w", title: "b", sessionId: "s2")
        mgr.activate(worktreeId: "w", tabId: t2.id)
        mgr.close(worktreeId: "w", tabId: t2.id)
        #expect(mgr.activeTabId(forWorktree: "w") == t1.id)
    }

    @Test func closingLastTabClearsActive() {
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: "w")) }
        let mgr = TabsManager()
        let t = mgr.appendTerminal(worktreeId: "w", title: "x", sessionId: "s")
        mgr.close(worktreeId: "w", tabId: t.id)
        #expect(mgr.tabs(forWorktree: "w").isEmpty)
        #expect(mgr.activeTabId(forWorktree: "w") == nil)
    }
}
