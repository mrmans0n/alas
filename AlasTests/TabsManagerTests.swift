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

    @Test func activatingTabNumberUsesOneBasedWorktreeLocalOrder() {
        let worktreeId = "tabs-manager-activate-tab-number"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let first = mgr.appendTerminal(worktreeId: worktreeId, title: "one", sessionId: "s1")
        let second = mgr.appendTerminal(worktreeId: worktreeId, title: "two", sessionId: "s2")

        #expect(mgr.activateTabNumber(1, worktreeId: worktreeId) == first.id)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
        #expect(mgr.activateTabNumber(2, worktreeId: worktreeId) == second.id)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == second.id)
    }

    @Test func activatingTabNumberIsScopedToWorktree() {
        let firstWorktreeId = "tabs-manager-activate-tab-number-a"
        let secondWorktreeId = "tabs-manager-activate-tab-number-b"
        defer {
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: firstWorktreeId))
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: secondWorktreeId))
        }
        let mgr = TabsManager()
        let firstA = mgr.appendTerminal(worktreeId: firstWorktreeId, title: "a1", sessionId: "a1")
        _ = mgr.appendTerminal(worktreeId: firstWorktreeId, title: "a2", sessionId: "a2")
        _ = mgr.appendTerminal(worktreeId: secondWorktreeId, title: "b1", sessionId: "b1")
        let secondB = mgr.appendTerminal(worktreeId: secondWorktreeId, title: "b2", sessionId: "b2")

        #expect(mgr.activateTabNumber(1, worktreeId: firstWorktreeId) == firstA.id)
        #expect(mgr.activeTabId(forWorktree: firstWorktreeId) == firstA.id)
        #expect(mgr.activeTabId(forWorktree: secondWorktreeId) == secondB.id)
    }

    @Test func activatingOutOfBoundsTabNumberIsNoOp() {
        let worktreeId = "tabs-manager-activate-tab-number-out-of-bounds"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        _ = mgr.appendTerminal(worktreeId: worktreeId, title: "one", sessionId: "s1")
        let second = mgr.appendTerminal(worktreeId: worktreeId, title: "two", sessionId: "s2")

        #expect(mgr.activateTabNumber(3, worktreeId: worktreeId) == nil)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == second.id)
    }

    @Test func activatingInvalidTabNumberIsNoOp() {
        let worktreeId = "tabs-manager-activate-tab-number-invalid"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: worktreeId, title: "one", sessionId: "s1")

        #expect(mgr.activateTabNumber(0, worktreeId: worktreeId) == nil)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == tab.id)
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

    @Test func nextTerminalTitleUsesStableNumericSuffix() {
        let worktreeId = "tabs-manager-terminal-title-suffix"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        #expect(mgr.nextTerminalTitle(worktreeId: worktreeId, baseTitle: "alas") == "alas")
        _ = mgr.appendTerminal(worktreeId: worktreeId, title: "alas", sessionId: "s1")
        #expect(mgr.nextTerminalTitle(worktreeId: worktreeId, baseTitle: "alas") == "alas 2")
        _ = mgr.appendTerminal(worktreeId: worktreeId, title: "alas 2", sessionId: "s2")
        #expect(mgr.nextTerminalTitle(worktreeId: worktreeId, baseTitle: "alas") == "alas 3")
    }

    @Test func renamingTerminalUpdatesTitleAndTrimsWhitespace() {
        let worktreeId = "tabs-manager-rename-terminal"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: worktreeId, title: "alas", sessionId: "s")

        let renamed = mgr.renameTerminal(worktreeId: worktreeId, tabId: tab.id, title: "  Server  ")

        #expect(renamed?.title == "Server")
        #expect(mgr.tabs(forWorktree: worktreeId).first?.title == "Server")
    }

    @Test func renamingTerminalRejectsEmptyTitle() {
        let worktreeId = "tabs-manager-rename-terminal-empty"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: worktreeId, title: "alas", sessionId: "s")

        let renamed = mgr.renameTerminal(worktreeId: worktreeId, tabId: tab.id, title: "   ")

        #expect(renamed == nil)
        #expect(mgr.tabs(forWorktree: worktreeId).first?.title == "alas")
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


    @Test func diffTabStateDecodesLegacyShapeAsUnstaged() throws {
        let json = #"""
        {"id":"d","title":"a.txt","relativePath":"a.txt"}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DiffTabState.self, from: json)
        #expect(decoded.relativePath == "a.txt")
        #expect(decoded.staged == false)
    }

    @Test func diffTabStateRoundTripsStagedFlag() throws {
        let state = DiffTabState(id: "d", title: "a.txt (staged)", relativePath: "a.txt", staged: true)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DiffTabState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.staged)
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

    @Test func openExternalEditorReuseRefreshesOriginatingRelativePath() {
        let worktreeId = "tabs-manager-reuse-refresh-origin"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let url = URL(fileURLWithPath: "/usr/include/foo.h")
        _ = mgr.openExternalEditor(
            worktreeId: worktreeId, absoluteURL: url,
            revealLine: 1, revealCharacter: 0,
            originatingRelativePath: "PkgA/Sources/main.swift"
        )
        let second = mgr.openExternalEditor(
            worktreeId: worktreeId, absoluteURL: url,
            revealLine: 5, revealCharacter: 2,
            originatingRelativePath: "PkgB/Sources/lib.swift"
        )
        if case .editor(let s) = second {
            #expect(s.originatingRelativePath == "PkgB/Sources/lib.swift")
            #expect(s.revealLine == 5)
        } else {
            Issue.record("expected editor tab")
        }
    }
}
