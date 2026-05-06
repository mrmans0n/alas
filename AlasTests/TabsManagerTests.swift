import Testing
import Foundation
@testable import Alas

struct TabsManagerTests {
    @Test func newTerminalAppendsAndActivates() {
        let worktreeId = "tabs-manager-new-terminal"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: worktreeId, title: "main", sessionId: "s")
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == tab.id)
    }

    @Test func closingActivatesNeighbour() {
        let worktreeId = "tabs-manager-closing-neighbour"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let t1 = mgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let t2 = mgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")
        mgr.activate(worktreeId: worktreeId, tabId: t2.id)
        mgr.close(worktreeId: worktreeId, tabId: t2.id)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == t1.id)
    }

    @Test func closingLastTabClearsActive() {
        let worktreeId = "tabs-manager-closing-last"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let t = mgr.appendTerminal(worktreeId: worktreeId, title: "x", sessionId: "s")
        mgr.close(worktreeId: worktreeId, tabId: t.id)
        #expect(mgr.tabs(forWorktree: worktreeId).isEmpty)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == nil)
    }

    @Test func replacingTerminalSessionKeepsTabAndActiveSelection() {
        let worktreeId = "tabs-manager-replace-session"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let t = mgr.appendTerminal(worktreeId: worktreeId, title: "x", sessionId: "old")

        let updated = mgr.replaceTerminalSession(worktreeId: worktreeId, tabId: t.id, sessionId: "new")

        #expect(updated?.id == t.id)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == t.id)
        guard case .terminal(let state) = mgr.tabs(forWorktree: worktreeId).first else {
            Issue.record("Expected terminal tab")
            return
        }
        #expect(state.sessionId == "new")
        #expect(state.title == "x")
    }
}
