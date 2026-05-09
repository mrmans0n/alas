import Testing
import Foundation
@testable import Alas

@MainActor
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

    @Test func editorTabStateDecodesLegacyShape() throws {
        // Old shape: no externalAbsolutePath key.
        let json = #"""
        {"id":"x","title":"a.txt","relativePath":"a.txt"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorTabState.self, from: json)
        #expect(decoded.relativePath == "a.txt")
        #expect(decoded.isExternal == false)
        #expect(decoded.externalAbsolutePath == nil)
    }

    @Test func editorTabStateRoundTripsExternalPath() throws {
        let s = EditorTabState(
            id: "y", title: "NSString.h",
            relativePath: "",
            externalAbsolutePath: "/usr/include/NSString.h"
        )
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(EditorTabState.self, from: data)
        #expect(back == s)
        #expect(back.isExternal)
    }

    @Test func openExternalEditorAppendsAndActivates() {
        let worktreeId = "tabs-manager-open-external"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.openExternalEditor(
            worktreeId: worktreeId,
            absoluteURL: URL(fileURLWithPath: "/usr/include/foo.h"),
            revealLine: 10, revealCharacter: 0
        )
        #expect(mgr.activeTabId(forWorktree: worktreeId) == tab.id)
        if case .editor(let s) = tab {
            #expect(s.isExternal)
            #expect(s.externalAbsolutePath == "/usr/include/foo.h")
            #expect(s.title == "foo.h")
            #expect(s.revealLine == 10)
        } else {
            Issue.record("expected editor tab")
        }
    }

    @Test func editorTabStateRoundTripsOriginatingRelativePath() throws {
        let s = EditorTabState(
            id: "z", title: "NSString.h",
            relativePath: "",
            externalAbsolutePath: "/usr/include/NSString.h",
            originatingRelativePath: "Foo/Bar.swift"
        )
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(EditorTabState.self, from: data)
        #expect(back == s)
        #expect(back.originatingRelativePath == "Foo/Bar.swift")
    }

    @Test func editorTabStateDecodesLegacyShapeWithoutOriginatingRelativePath() throws {
        // Old shape: no originatingRelativePath key. Must decode cleanly.
        let json = #"""
        {"id":"z","title":"NSString.h","relativePath":"","externalAbsolutePath":"/usr/include/NSString.h"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorTabState.self, from: json)
        #expect(decoded.isExternal)
        #expect(decoded.originatingRelativePath == nil)
    }

    @Test func openExternalEditorReusesExistingTab() {
        let worktreeId = "tabs-manager-reuse-external"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let url = URL(fileURLWithPath: "/usr/include/foo.h")
        let first = mgr.openExternalEditor(worktreeId: worktreeId, absoluteURL: url, revealLine: 1, revealCharacter: 0)
        let second = mgr.openExternalEditor(worktreeId: worktreeId, absoluteURL: url, revealLine: 5, revealCharacter: 2)
        #expect(first.id == second.id)
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        if case .editor(let s) = second {
            #expect(s.revealLine == 5)
            #expect(s.revealCharacter == 2)
        }
    }
}
