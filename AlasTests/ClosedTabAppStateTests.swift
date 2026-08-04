import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ClosedTabAppStateTests {
    private enum ReopenTestError: Error {
        case sessionOpenFailed
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    private struct Fixture {
        let state: AppState
        let first: Worktree
        let second: Worktree
    }

    private func makeFixture(state: AppState = AppState(store: MemoryStore())) -> Fixture {
        let project = ProjectConfig(
            id: "closed-tabs-project",
            name: "Closed Tabs",
            path: "/tmp/closed-tabs-project",
            color: "blue",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let first = Worktree(
            id: "closed-tabs-first",
            projectId: project.id,
            name: "first",
            branch: "first",
            path: URL(fileURLWithPath: "/tmp/closed-tabs-first"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let second = Worktree(
            id: "closed-tabs-second",
            projectId: project.id,
            name: "second",
            branch: "second",
            path: URL(fileURLWithPath: "/tmp/closed-tabs-second"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(first)
        state.projectsManager.insertOptimisticWorktree(second)
        return Fixture(state: state, first: first, second: second)
    }

    @Test func explicitCloseRecordsAndReopenSwitchesWorktree() async {
        let fixture = makeFixture()
        let tab = fixture.state.tabs.appendEditor(
            worktreeId: fixture.second.id,
            title: "README.md",
            relativePath: "README.md"
        )
        fixture.state.selectWorktree(id: fixture.first.id)

        fixture.state.requestCloseTab(worktreeId: fixture.second.id, tabId: tab.id)
        #expect(fixture.state.canReopenClosedTab)

        await fixture.state.reopenLastClosedTab()

        #expect(fixture.state.selectedWorktreeId == fixture.second.id)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.second.id) == tab.id)
        #expect(!fixture.state.canReopenClosedTab)
    }

    @Test func automaticCloseDoesNotRecordHistory() {
        let fixture = makeFixture()
        let tab = fixture.state.tabs.appendEditor(
            worktreeId: fixture.first.id,
            title: "README.md",
            relativePath: "README.md"
        )

        fixture.state.closeTab(worktreeId: fixture.first.id, tabId: tab.id)

        #expect(!fixture.state.canReopenClosedTab)
    }

    @Test func explicitGlobalCloseRecordsAndReopensMission() async {
        let fixture = makeFixture()
        let tab = fixture.state.globalTabs.openOrFocusMission(missionID: MissionID(rawValue: "closed-tabs-mission"), title: "Mission")

        fixture.state.requestCloseGlobalTab(tabID: tab.id)
        #expect(fixture.state.canReopenClosedTab)

        await fixture.state.reopenLastClosedTab()

        #expect(fixture.state.globalTabs.activeTabId == tab.id)
        #expect(fixture.state.globalTabs.tabs.count == 1)
    }

    @Test func reopenFocusesManuallyRestoredGlobalTabWithoutDuplication() async {
        let fixture = makeFixture()
        let tab = fixture.state.globalTabs.openOrFocusMission(missionID: MissionID(rawValue: "closed-tabs-mission"), title: "Mission")
        fixture.state.requestCloseGlobalTab(tabID: tab.id)
        _ = fixture.state.globalTabs.restore(
            tab: tab,
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )

        await fixture.state.reopenLastClosedTab()

        #expect(fixture.state.globalTabs.tabs.map(\.id) == [tab.id])
        #expect(fixture.state.globalTabs.activeTabId == tab.id)
        #expect(!fixture.state.canReopenClosedTab)
    }

    @Test func canceledTerminalCloseDoesNotRecordHistory() {
        let project = ProjectConfig(
            id: "closed-tabs-confirmation-project",
            name: "Closed Tabs",
            path: "/tmp/closed-tabs-confirmation-project",
            color: "blue",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let worktree = Worktree(
            id: "closed-tabs-confirmation-worktree",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/closed-tabs-confirmation-worktree"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = AppState(store: MemoryStore(), closeTabConfirmer: { _ in false })
        state.config.terminal.confirmCloseTabs = true
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        state.projectsManager.insertOptimisticWorktree(worktree)
        let tab = state.tabs.appendTerminal(worktreeId: worktree.id, title: "Terminal", sessionId: "session")

        state.requestCloseTab(worktreeId: worktree.id, tabId: tab.id)

        #expect(!state.canReopenClosedTab)
        #expect(state.tabs.tabs(forWorktree: worktree.id).contains(where: { $0.id == tab.id }))
    }

    @Test func closeCenterTabsRecordsGlobalAndLocalTabsInVisibleOrder() {
        let fixture = makeFixture()
        let global = fixture.state.globalTabs.openOrFocusMission(missionID: MissionID(rawValue: "closed-tabs-mission"), title: "Mission")
        let local = fixture.state.tabs.appendEditor(
            worktreeId: fixture.first.id,
            title: "README.md",
            relativePath: "README.md"
        )

        fixture.state.closeCenterTabs(worktreeId: fixture.first.id, tabIds: [global.id, local.id])

        #expect(fixture.state.closedTabHistory.entries.map(\.snapshot.tabID) == [global.id, local.id])
    }

    @Test func reopeningTerminalRebuildsLayoutWithFreshSessions() async {
        var openedCwds: [String?] = []
        var openedIDs = ["fresh-1", "fresh-2"]
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, forcedCwd, startupScriptSuffix, includeUserStartupScript, environmentOverrides, environmentRemovals in
                openedCwds.append(forcedCwd?.path)
                #expect(startupScriptSuffix == nil)
                #expect(includeUserStartupScript)
                #expect(environmentOverrides.isEmpty)
                #expect(environmentRemovals.isEmpty)
                return .init(id: openedIDs.removeFirst(), foregroundPid: { nil })
            }
        )
        let fixture = makeFixture(state: state)
        let original = TerminalTabState(
            id: "reopen-terminal",
            title: "Terminal",
            root: .split(PaneSplit(
                id: "split-id",
                axis: .vertical,
                fraction: 0.37,
                children: [
                    .leaf(PaneLeaf(id: "old-1", sessionId: "old-1", lastCwd: "/tmp/first")),
                    .leaf(PaneLeaf(id: "old-2", sessionId: "old-2", lastCwd: "/tmp/second"))
                ]
            )),
            focusedLeafId: "old-2",
            runScriptKey: "worktree:run.sh",
            runScriptLeafId: "old-2"
        )
        _ = fixture.state.tabs.restore(
            tab: .terminal(original),
            worktreeID: fixture.first.id,
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: original.id)

        await fixture.state.reopenLastClosedTab()

        #expect(openedCwds == ["/tmp/first", "/tmp/second"])
        guard case .terminal(let reopened) = fixture.state.tabs.activeTab(forWorktree: fixture.first.id) else {
            Issue.record("Expected reopened terminal")
            return
        }
        #expect(reopened.id == original.id)
        #expect(reopened.root.leaves().map(\.id) == ["fresh-1", "fresh-2"])
        #expect(reopened.root.leaves().map(\.lastCwd) == ["/tmp/first", "/tmp/second"])
        #expect(reopened.focusedLeafId == "fresh-2")
        #expect(reopened.runScriptKey == nil)
        #expect(reopened.runScriptLeafId == nil)
        guard case .split(let split) = reopened.root else {
            Issue.record("Expected split terminal layout")
            return
        }
        #expect(split.id == "split-id")
        #expect(split.axis == .vertical)
        #expect(split.fraction == 0.37)
        #expect(split.children.map { $0.firstLeaf().id } == ["fresh-1", "fresh-2"])
    }

    @Test func failedTerminalReopenRollsBackOpenedSessionsAndRetainsHistory() async {
        var openAttempts = 0
        var errorTitle: String?
        let state = AppState(
            store: MemoryStore(),
            fileActionErrorHandler: { title, _ in errorTitle = title },
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openAttempts += 1
                if openAttempts == 2 { throw ReopenTestError.sessionOpenFailed }
                return .init(id: "fresh-1", foregroundPid: { nil })
            }
        )
        let fixture = makeFixture(state: state)
        let original = TerminalTabState(
            id: "reopen-terminal-failure",
            title: "Terminal",
            root: .split(PaneSplit(
                id: "split-id",
                axis: .vertical,
                fraction: 0.5,
                children: [
                    .leaf(PaneLeaf(id: "old-1", sessionId: "old-1", lastCwd: "/tmp/first")),
                    .leaf(PaneLeaf(id: "old-2", sessionId: "old-2", lastCwd: "/tmp/second"))
                ]
            )),
            focusedLeafId: "old-1"
        )
        _ = fixture.state.tabs.restore(
            tab: .terminal(original),
            worktreeID: fixture.first.id,
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: original.id)

        await fixture.state.reopenLastClosedTab()

        #expect(errorTitle == "Reopen Tab Failed")
        #expect(fixture.state.tabs.tabs(forWorktree: fixture.first.id).isEmpty)
        #expect(fixture.state.canReopenClosedTab)
        #expect(fixture.state.closedTabHistory.last?.snapshot.tabID == original.id)
        #expect(!fixture.state.harness.detector.isRegistered(sessionId: "fresh-1"))
    }

    @Test func reopenDiscardsStaleWorktreeEntryAndRestoresNextEntry() async {
        let fixture = makeFixture()
        let valid = fixture.state.tabs.appendEditor(worktreeId: fixture.first.id, title: "valid", relativePath: "valid")
        let stale = fixture.state.tabs.appendEditor(worktreeId: fixture.second.id, title: "stale", relativePath: "stale")
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: valid.id)
        fixture.state.requestCloseTab(worktreeId: fixture.second.id, tabId: stale.id)
        fixture.state.projectsManager.removeOptimisticWorktree(id: fixture.second.id, projectId: fixture.second.projectId)

        await fixture.state.reopenLastClosedTab()

        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.first.id) == valid.id)
        #expect(!fixture.state.canReopenClosedTab)
    }

    @Test func worktreeCleanupPurgesItsClosedTabEntries() {
        let fixture = makeFixture()
        let tab = fixture.state.tabs.appendEditor(worktreeId: fixture.first.id, title: "README.md", relativePath: "README.md")
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: tab.id)

        fixture.state.archiveWorktree(fixture.first)

        #expect(!fixture.state.canReopenClosedTab)
        #expect(fixture.state.closedTabHistory.entries.isEmpty)
    }
}
