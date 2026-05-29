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
        #expect(state.root.find(leafId: state.focusedLeafId)?.leaf.sessionId == "new")
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

    @Test func imagePreviewTabStateRoundTrips() throws {
        let state = ImagePreviewTabState(id: "img", title: "logo.png", relativePath: "Assets/logo.png")
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ImagePreviewTabState.self, from: data)
        #expect(decoded == state)
    }

    @Test func imagePreviewTabRoundTripsAndExposesFilePath() throws {
        let tab = Tab.imagePreview(ImagePreviewTabState(id: "img", title: "logo.png", relativePath: "Assets/logo.png"))
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)
        #expect(decoded == tab)
        #expect(decoded.id == "img")
        #expect(decoded.title == "logo.png")
        #expect(decoded.iconName == "image")
        #expect(decoded.relativeFilePath == "Assets/logo.png")
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

    @Test func openImagePreviewAppendsAndActivates() {
        let worktreeId = "tabs-manager-open-image-preview"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let tab = mgr.openImagePreview(worktreeId: worktreeId, relativePath: "Assets/logo.png")

        #expect(mgr.activeTabId(forWorktree: worktreeId) == tab.id)
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        guard case .imagePreview(let state) = tab else {
            Issue.record("expected image preview tab")
            return
        }
        #expect(state.title == "logo.png")
        #expect(state.relativePath == "Assets/logo.png")
    }

    @Test func openImagePreviewReusesExistingTab() {
        let worktreeId = "tabs-manager-reuse-image-preview"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openImagePreview(worktreeId: worktreeId, relativePath: "Assets/logo.png")
        _ = mgr.appendTerminal(worktreeId: worktreeId, title: "main", sessionId: "s")
        let second = mgr.openImagePreview(worktreeId: worktreeId, relativePath: "Assets/logo.png")

        #expect(first.id == second.id)
        #expect(mgr.tabs(forWorktree: worktreeId).count == 2)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
    }

    @Test func openImagePreviewCreatesSeparateTabsForDifferentPaths() {
        let worktreeId = "tabs-manager-different-image-previews"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openImagePreview(worktreeId: worktreeId, relativePath: "Assets/logo.png")
        let second = mgr.openImagePreview(worktreeId: worktreeId, relativePath: "Assets/banner.png")

        #expect(first.id != second.id)
        #expect(mgr.tabs(forWorktree: worktreeId).count == 2)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == second.id)
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

    @Test func moveTabReordersTabs() {
        let worktreeId = "tabs-manager-move-tab"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let a = mgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let b = mgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")
        let c = mgr.appendTerminal(worktreeId: worktreeId, title: "c", sessionId: "s3")

        mgr.moveTab(worktreeId: worktreeId, fromId: a.id, toId: c.id)

        let ids = mgr.tabs(forWorktree: worktreeId).map(\.id)
        #expect(ids == [b.id, c.id, a.id])
    }

    @Test func moveTabPreservesActiveTabId() {
        let worktreeId = "tabs-manager-move-tab-active"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let a = mgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let b = mgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")
        mgr.activate(worktreeId: worktreeId, tabId: a.id)

        mgr.moveTab(worktreeId: worktreeId, fromId: a.id, toId: b.id)

        #expect(mgr.activeTabId(forWorktree: worktreeId) == a.id)
    }

    @Test func moveTabMissingSourceIsNoOp() {
        let worktreeId = "tabs-manager-move-tab-missing-source"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let a = mgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let b = mgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")

        mgr.moveTab(worktreeId: worktreeId, fromId: "missing", toId: b.id)

        let ids = mgr.tabs(forWorktree: worktreeId).map(\.id)
        #expect(ids == [a.id, b.id])
    }

    @Test func moveTabMissingDestinationIsNoOp() {
        let worktreeId = "tabs-manager-move-tab-missing-destination"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let a = mgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let b = mgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")

        mgr.moveTab(worktreeId: worktreeId, fromId: a.id, toId: "missing")

        let ids = mgr.tabs(forWorktree: worktreeId).map(\.id)
        #expect(ids == [a.id, b.id])
    }

    @Test func moveTabSameIdIsNoOp() {
        let worktreeId = "tabs-manager-move-tab-same"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let a = mgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let b = mgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")

        mgr.moveTab(worktreeId: worktreeId, fromId: a.id, toId: a.id)

        let ids = mgr.tabs(forWorktree: worktreeId).map(\.id)
        #expect(ids == [a.id, b.id])
    }

    @Test func moveTabPersistsOrder() {
        let worktreeId = "tabs-manager-move-tab-persist"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let firstMgr = TabsManager()
        let a = firstMgr.appendTerminal(worktreeId: worktreeId, title: "a", sessionId: "s1")
        let b = firstMgr.appendTerminal(worktreeId: worktreeId, title: "b", sessionId: "s2")
        let c = firstMgr.appendTerminal(worktreeId: worktreeId, title: "c", sessionId: "s3")
        firstMgr.moveTab(worktreeId: worktreeId, fromId: a.id, toId: c.id)

        let secondMgr = TabsManager()
        secondMgr.loadAll(worktreeIds: [worktreeId])
        let ids = secondMgr.tabs(forWorktree: worktreeId).map(\.id)
        #expect(ids == [b.id, c.id, a.id])
    }

    @Test func commitEditorTabStateUsesOriginalShaForStableIdentity() {
        let state = CommitEditorTabState(
            worktreeId: "wt",
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            title: "bbbbbbb edited subject"
        )

        #expect(state.id == "commit-editor:wt:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(state.currentSha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(state.title == "bbbbbbb edited subject")
    }

    @Test func commitEditorTabRoundTrips() throws {
        let tab = Tab.commitEditor(CommitEditorTabState(
            worktreeId: "wt",
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            title: "aaaaaaa subject"
        ))

        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(Tab.self, from: data)

        #expect(decoded == tab)
        #expect(decoded.id == "commit-editor:wt:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(decoded.title == "aaaaaaa subject")
        #expect(decoded.iconName == "commit")
    }

    @Test func appendCommitEditorReusesOriginalShaIdentityWithoutOverwritingCurrentSha() {
        let worktreeId = "tabs-manager-commit-editor"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            title: "aaaaaaa original"
        )
        let second = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            title: "bbbbbbb updated"
        )

        #expect(first.id == second.id)
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
        guard case .commitEditor(let state) = mgr.tabs(forWorktree: worktreeId).first else {
            Issue.record("Expected commit editor tab")
            return
        }
        #expect(state.currentSha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(state.title == "aaaaaaa original")
    }

    @Test func openCommitEditorReuseDoesNotRegressCurrentSha() {
        let worktreeId = "tabs-manager-commit-editor-no-regress"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            title: "bbbbbbb rewritten"
        )
        let second = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            title: "aaaaaaa stale"
        )

        #expect(first.id == second.id)
        guard case .commitEditor(let state) = second else {
            Issue.record("Expected commit editor tab")
            return
        }
        #expect(state.currentSha == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        #expect(state.title == "bbbbbbb rewritten")
    }

    @Test func findsCommitEditorByCurrentShaAfterRewrite() {
        let worktreeId = "tabs-manager-commit-editor-current-sha"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let editor = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            title: "bbbbbbb updated"
        )
        _ = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "cccccccccccccccccccccccccccccccccccccccc",
            currentSha: "cccccccccccccccccccccccccccccccccccccccc",
            title: "ccccccc other"
        )

        let found = mgr.commitEditorTab(worktreeId: worktreeId, currentSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

        #expect(found?.id == editor.id)
    }

    @Test func updateCommitEditorShasAppliesShaMapToOpenCommitEditors() {
        let worktreeId = "tabs-manager-commit-editor-sha-map"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let target = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            currentSha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            title: "bbbbbbb target"
        )
        let descendant = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "origin/main",
            originalSha: "cccccccccccccccccccccccccccccccccccccccc",
            currentSha: "dddddddddddddddddddddddddddddddddddddddd",
            title: "ddddddd descendant"
        )

        mgr.updateCommitEditorShas(worktreeId: worktreeId, shaMap: [
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            "dddddddddddddddddddddddddddddddddddddddd": "ffffffffffffffffffffffffffffffffffffffff"
        ])

        #expect(mgr.commitEditorTab(worktreeId: worktreeId, currentSha: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")?.id == target.id)
        #expect(mgr.commitEditorTab(worktreeId: worktreeId, currentSha: "ffffffffffffffffffffffffffffffffffffffff")?.id == descendant.id)
    }
}

// MARK: - Pane tree mutations

@MainActor
struct TabsManagerPaneTests {
    @Test func setFocusedLeafUpdatesState() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        guard case .terminal(let initialState) = tab else {
            Issue.record("expected terminal tab")
            return
        }
        let originalFocus = initialState.focusedLeafId

        // Split the focused leaf so there's a second leaf to focus.
        _ = mgr.splitFocusedLeaf(worktreeId: "wt", tabId: tab.id, axis: .vertical,
                                  newLeafId: "new-leaf", newSessionId: "s2")

        _ = mgr.setFocusedLeaf(worktreeId: "wt", tabId: tab.id, leafId: originalFocus)
        guard let reread = mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id }),
              case .terminal(let s) = reread else {
            Issue.record("expected terminal tab in store after setFocusedLeaf")
            return
        }
        #expect(s.focusedLeafId == originalFocus)
    }

    @Test func splitFocusedLeafReplacesFocusedLeafWithSplit() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        let result = mgr.splitFocusedLeaf(
            worktreeId: "wt", tabId: tab.id, axis: .horizontal,
            newLeafId: "new", newSessionId: "s2"
        )
        guard case .terminal(let s) = result,
              case .split(let split) = s.root else {
            Issue.record("expected a split at root")
            return
        }
        #expect(split.axis == .horizontal)
        #expect(split.fraction == 0.5)
        #expect(split.children.count == 2)
        #expect(s.focusedLeafId == "new")
        // Re-read to confirm persistence
        guard let reread = mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id }),
              case .terminal(let persisted) = reread,
              case .split(let persistedSplit) = persisted.root else {
            Issue.record("split did not persist into byWorktree")
            return
        }
        #expect(persistedSplit.axis == .horizontal)
        #expect(persistedSplit.children.count == 2)
        #expect(persisted.focusedLeafId == "new")
    }

    @Test func removeFocusedLeafReturnsClosedLeafId() throws {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        _ = mgr.splitFocusedLeaf(
            worktreeId: "wt", tabId: tab.id, axis: .vertical,
            newLeafId: "new", newSessionId: "s2"
        )
        let outcome = try #require(mgr.removeFocusedLeaf(worktreeId: "wt", tabId: tab.id))
        guard case .leafRemoved(let outcomeTab, let closedLeafId) = outcome else {
            Issue.record("expected .leafRemoved")
            return
        }
        // The focused leaf after split is "new" (the new leaf id), so that's what's closed.
        #expect(closedLeafId == "new")
        if case .terminal(let s) = outcomeTab, case .leaf(let l) = s.root {
            #expect(l.sessionId == "s1")
            #expect(s.focusedLeafId == l.id)
        } else {
            Issue.record("expected leaf root after collapse")
        }
        // Re-read to confirm persistence
        guard let reread = mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id }),
              case .terminal(let persisted) = reread,
              case .leaf(let persistedLeaf) = persisted.root else {
            Issue.record("collapse did not persist into byWorktree")
            return
        }
        #expect(persistedLeaf.sessionId == "s1")
        #expect(persisted.focusedLeafId == persistedLeaf.id)
    }

    @Test func removeFocusedLeafSignalsLastLeafRemoval() throws {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        // Capture the leaf id before removal (it is a stable UUID, not the session id).
        guard case .terminal(let tabState) = tab, case .leaf(let initialLeaf) = tabState.root else {
            Issue.record("expected single-leaf terminal tab")
            return
        }
        let expectedLeafId = initialLeaf.id
        let outcome = try #require(mgr.removeFocusedLeaf(worktreeId: "wt", tabId: tab.id))
        guard case .tabRemoved(let closedLeafId) = outcome else {
            Issue.record("expected .tabRemoved")
            return
        }
        #expect(closedLeafId == expectedLeafId)
    }

    @Test func removeLeafBySpecificIdCollapsesSibling() throws {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        guard case .terminal(let initial) = tab,
              case .leaf(let originalLeaf) = initial.root else {
            Issue.record("expected single-leaf terminal tab")
            return
        }
        _ = mgr.splitFocusedLeaf(
            worktreeId: "wt", tabId: tab.id, axis: .vertical,
            newLeafId: "new", newSessionId: "s2"
        )
        // Remove the ORIGINAL (non-focused) leaf by id. Focus is currently on "new".
        let outcome = try #require(mgr.removeLeaf(
            worktreeId: "wt", tabId: tab.id, leafId: originalLeaf.id
        ))
        guard case .leafRemoved(let outcomeTab, let closedLeafId) = outcome else {
            Issue.record("expected .leafRemoved")
            return
        }
        #expect(closedLeafId == originalLeaf.id)
        if case .terminal(let s) = outcomeTab, case .leaf(let l) = s.root {
            #expect(l.id == "new")
            #expect(s.focusedLeafId == "new")
        } else {
            Issue.record("expected leaf root after collapse")
        }
    }

    @Test func removeLeafResetsFocusWhenFocusedLeafRemoved() throws {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        guard case .terminal(let initial) = tab,
              case .leaf(let originalLeaf) = initial.root else {
            Issue.record("expected single-leaf terminal tab")
            return
        }
        _ = mgr.splitFocusedLeaf(
            worktreeId: "wt", tabId: tab.id, axis: .vertical,
            newLeafId: "new", newSessionId: "s2"
        )
        // Remove the FOCUSED leaf ("new"). Focus must move to the surviving leaf.
        let outcome = try #require(mgr.removeLeaf(
            worktreeId: "wt", tabId: tab.id, leafId: "new"
        ))
        guard case .leafRemoved(_, let closedLeafId) = outcome else {
            Issue.record("expected .leafRemoved")
            return
        }
        #expect(closedLeafId == "new")
        guard case .terminal(let persisted) = (mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id })!),
              case .leaf(let persistedLeaf) = persisted.root else {
            Issue.record("expected single-leaf root")
            return
        }
        #expect(persistedLeaf.id == originalLeaf.id)
        #expect(persisted.focusedLeafId == originalLeaf.id)
    }

    @Test func removeLeafReturnsTabRemovedForLastLeaf() throws {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        guard case .terminal(let initial) = tab,
              case .leaf(let onlyLeaf) = initial.root else {
            Issue.record("expected single-leaf terminal tab")
            return
        }
        let outcome = try #require(mgr.removeLeaf(
            worktreeId: "wt", tabId: tab.id, leafId: onlyLeaf.id
        ))
        guard case .tabRemoved(let closedLeafId) = outcome else {
            Issue.record("expected .tabRemoved")
            return
        }
        #expect(closedLeafId == onlyLeaf.id)
    }

    @Test func removeLeafReturnsNilForUnknownLeaf() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        let outcome = mgr.removeLeaf(
            worktreeId: "wt", tabId: tab.id, leafId: "nope"
        )
        #expect(outcome == nil)
    }

    @Test func removeLeafReturnsNilForUnknownTab() {
        let mgr = TabsManager()
        let outcome = mgr.removeLeaf(
            worktreeId: "wt", tabId: "ghost-tab", leafId: "any"
        )
        #expect(outcome == nil)
    }

    @Test func removeLeafTwiceIsNoOp() throws {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        _ = mgr.splitFocusedLeaf(
            worktreeId: "wt", tabId: tab.id, axis: .vertical,
            newLeafId: "new", newSessionId: "s2"
        )
        // First removal succeeds.
        let first = try #require(mgr.removeLeaf(
            worktreeId: "wt", tabId: tab.id, leafId: "new"
        ))
        guard case .leafRemoved = first else {
            Issue.record("expected .leafRemoved")
            return
        }
        // Second removal of the same leaf must be a quiet no-op — the
        // process-exit handler relies on this to race manual close.
        let second = mgr.removeLeaf(
            worktreeId: "wt", tabId: tab.id, leafId: "new"
        )
        #expect(second == nil)
    }

    @Test func setSplitFractionClampsBetween0_1And0_9() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        _ = mgr.splitFocusedLeaf(
            worktreeId: "wt", tabId: tab.id, axis: .vertical,
            newLeafId: "new", newSessionId: "s2"
        )
        guard case .terminal(let s) = (mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id })!),
              case .split(let split) = s.root else {
            Issue.record("expected split")
            return
        }

        _ = mgr.setSplitFraction(worktreeId: "wt", tabId: tab.id, splitId: split.id, fraction: 1.5)
        if case .terminal(let s2) = (mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id })!),
           case .split(let s2split) = s2.root {
            #expect(s2split.fraction == 0.9)
        }

        _ = mgr.setSplitFraction(worktreeId: "wt", tabId: tab.id, splitId: split.id, fraction: -0.5)
        if case .terminal(let s3) = (mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id })!),
           case .split(let s3split) = s3.root {
            #expect(s3split.fraction == 0.1)
        }
    }

    @Test func setLeafCwdUpdatesLastCwd() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "s1")
        guard case .terminal(let initialState) = tab else { Issue.record("not terminal")
        return }
        _ = mgr.setLeafCwd(worktreeId: "wt", tabId: tab.id,
                           leafId: initialState.focusedLeafId, cwd: "/Users/test")
        if case .terminal(let s) = (mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id })!),
           case .leaf(let l) = s.root {
            #expect(l.lastCwd == "/Users/test")
        }
    }

    @Test func replaceLeafSessionPreservesLastCwd() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "t", sessionId: "old")
        guard case .terminal(let initial) = tab else { Issue.record("not terminal")
        return }

        // Seed a lastCwd on the leaf via setLeafCwd.
        _ = mgr.setLeafCwd(worktreeId: "wt", tabId: tab.id,
                           leafId: initial.focusedLeafId, cwd: "/tmp/work")

        // Swap the session for that leaf.
        _ = mgr.replaceLeafSession(worktreeId: "wt", tabId: tab.id,
                                   leafId: initial.focusedLeafId, sessionId: "new")

        guard let reread = mgr.tabs(forWorktree: "wt").first(where: { $0.id == tab.id }),
              case .terminal(let s) = reread,
              case .leaf(let l) = s.root else {
            Issue.record("expected single-leaf tab after replaceLeafSession")
            return
        }
        #expect(l.sessionId == "new")
        #expect(l.lastCwd == "/tmp/work",
                "lastCwd should be preserved across session replacement")
    }
}

// MARK: - Terminal runtime titles

@MainActor
struct TabsManagerRuntimeTitleTests {
    @Test func setTerminalRuntimeTitleStoresTitle() {
        let mgr = TabsManager()
        mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "vim foo")
        #expect(mgr.terminalRuntimeTitles["leaf1"] == "vim foo")
    }

    @Test func setTerminalRuntimeTitleIgnoresEmptyTitle() {
        let mgr = TabsManager()
        mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "vim foo")
        mgr.setTerminalRuntimeTitle(leafId: "leaf1", title: "")
        #expect(mgr.terminalRuntimeTitles["leaf1"] == "vim foo")
    }

    @Test func closingTerminalTabCleansUpRuntimeTitles() {
        let worktreeId = "wt"
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: worktreeId, title: "bash", sessionId: "s1")
        guard case .terminal(let state) = tab else {
            Issue.record("Expected terminal tab")
            return
        }
        let leafId = state.focusedLeafId
        mgr.setTerminalRuntimeTitle(leafId: leafId, title: "vim foo")
        mgr.close(worktreeId: worktreeId, tabId: tab.id)
        #expect(mgr.terminalRuntimeTitles[leafId] == nil)
    }

    @Test func displayTerminalTitleReturnsFocusedLeafTitle() {
        let mgr = TabsManager()
        let tab = mgr.appendTerminal(worktreeId: "wt", title: "bash", sessionId: "s1")
        guard case .terminal(let state) = tab else {
            Issue.record("Expected terminal tab")
            return
        }
        mgr.setTerminalRuntimeTitle(leafId: state.focusedLeafId, title: "vim foo")
        #expect(mgr.displayTerminalTitle(for: tab) == "vim foo")
    }

    @Test func displayTerminalTitleReturnsNilForNonTerminalTab() {
        let mgr = TabsManager()
        let tab = mgr.appendEditor(worktreeId: "wt", title: "README.md", relativePath: "README.md")
        #expect(mgr.displayTerminalTitle(for: tab) == nil)
    }

    @Test func hasLoadedIsFalseBeforeLoadAll() {
        let mgr = TabsManager()
        #expect(mgr.hasLoaded == false)
    }

    @Test func hasLoadedIsTrueAfterLoadAll() {
        let mgr = TabsManager()
        mgr.loadAll(worktreeIds: [])
        #expect(mgr.hasLoaded == true)
    }
}
