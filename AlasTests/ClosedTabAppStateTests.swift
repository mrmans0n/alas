import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ClosedTabAppStateTests {
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

    @Test func overlappingTerminalReopenDoesNotStartSecondAttempt() async {
        var attempts = 0
        var placeholderContinuation: CheckedContinuation<Void, Never>?
        let state = AppState(
            store: MemoryStore(),
            terminalTabReopenPlaceholder: { _, _, _ in
                attempts += 1
                await withCheckedContinuation { continuation in
                    placeholderContinuation = continuation
                }
            }
        )
        let fixture = makeFixture(state: state)
        let tab = fixture.state.tabs.appendTerminal(worktreeId: fixture.first.id, title: "Terminal", sessionId: "session")
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: tab.id)

        let reopenTask = Task { await fixture.state.reopenLastClosedTab() }
        while placeholderContinuation == nil {
            await Task.yield()
        }
        #expect(fixture.state.isReopeningClosedTab)

        await fixture.state.reopenLastClosedTab()
        #expect(attempts == 1)

        placeholderContinuation?.resume()
        await reopenTask.value

        #expect(attempts == 1)
        #expect(fixture.state.canReopenClosedTab)
        #expect(fixture.state.closedTabHistory.entries.map(\.snapshot.tabID) == [tab.id])
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
