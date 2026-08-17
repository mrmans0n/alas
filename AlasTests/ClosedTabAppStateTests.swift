import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct ClosedTabAppStateTests {
    private enum ReopenTestError: Error {
        case sessionOpenFailed
    }

    private actor AsyncGate {
        private var entered = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func enterAndWait() async {
            entered = true
            let waiters = entryWaiters
            entryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { continuation in
                entryWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
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

    private func makeFixture(
        state: AppState = AppState(store: MemoryStore())
    ) -> Fixture {
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

    @Test func centerTabNavigationUsesTheWorktreeActiveTab() {
        let fixture = makeFixture()
        let first = fixture.state.tabs.appendEditor(
            worktreeId: fixture.first.id,
            title: "one",
            relativePath: "one.md"
        )
        let second = fixture.state.tabs.appendEditor(
            worktreeId: fixture.first.id,
            title: "two",
            relativePath: "two.md"
        )
        let third = fixture.state.tabs.appendEditor(
            worktreeId: fixture.first.id,
            title: "three",
            relativePath: "three.md"
        )
        _ = fixture.state.tabs.appendEditor(
            worktreeId: fixture.second.id,
            title: "other",
            relativePath: "other.md"
        )

        fixture.state.activateWorktreeCenterTab(worktreeId: fixture.first.id, tabId: second.id)

        #expect(fixture.state.activateCenterTabNumber(1, worktreeId: fixture.first.id) == first.id)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.first.id) == first.id)

        fixture.state.activateWorktreeCenterTab(worktreeId: fixture.first.id, tabId: second.id)

        #expect(fixture.state.activateAdjacentCenterTab(.next, worktreeId: fixture.first.id) == third.id)
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.first.id) == third.id)
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

    @Test func reopenACPSessionWaitsForCloseDetachBeforeRestoring() async {
        let gate = AsyncGate()
        var detachCalls = 0
        let state = AppState(
            store: MemoryStore(),
            acpDetachRunner: { _, _ in
                detachCalls += 1
                await gate.enterAndWait()
            }
        )
        let fixture = makeFixture(state: state)
        _ = fixture.state.acpManager(for: fixture.first)
        let tab = fixture.state.tabs.append(
            acpSession: ACPSessionTabState(sessionId: "closed-acp", title: "Closed chat"),
            to: fixture.first.id
        )

        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: tab.id)
        await gate.waitUntilEntered()

        let reopenTask = Task { @MainActor in
            await fixture.state.reopenLastClosedTab()
        }
        await Task.yield()

        #expect(detachCalls == 1)
        #expect(fixture.state.tabs.tabs(forWorktree: fixture.first.id).isEmpty)
        #expect(!fixture.state.canReopenClosedTab)

        await gate.release()
        await reopenTask.value

        #expect(fixture.state.tabs.tabs(forWorktree: fixture.first.id).map(\.id) == [tab.id])
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.first.id) == tab.id)
        #expect(!fixture.state.canReopenClosedTab)
    }

    @Test func completedACPDetachIsDroppedEvenWithoutReopen() async {
        let gate = AsyncGate()
        let state = AppState(
            store: MemoryStore(),
            acpDetachRunner: { _, _ in
                await gate.enterAndWait()
            }
        )
        let fixture = makeFixture(state: state)
        _ = fixture.state.acpManager(for: fixture.first)
        let tab = fixture.state.tabs.append(
            acpSession: ACPSessionTabState(sessionId: "drop-detach", title: "Closed chat"),
            to: fixture.first.id
        )

        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: tab.id)
        await gate.waitUntilEntered()

        #expect(fixture.state.pendingACPDetachCountForTesting == 1)

        await gate.release()
        for _ in 0 ..< 20 where fixture.state.pendingACPDetachCountForTesting != 0 {
            await Task.yield()
        }

        #expect(fixture.state.pendingACPDetachCountForTesting == 0)
        #expect(fixture.state.canReopenClosedTab)
    }

    @Test func reopeningACPSessionDoesNotRestoreAfterWorktreeCleanupDuringDetach() async {
        let gate = AsyncGate()
        let state = AppState(
            store: MemoryStore(),
            acpDetachRunner: { _, _ in
                await gate.enterAndWait()
            }
        )
        let fixture = makeFixture(state: state)
        _ = fixture.state.acpManager(for: fixture.first)
        let tab = fixture.state.tabs.append(
            acpSession: ACPSessionTabState(sessionId: "removed-worktree-chat", title: "Closed chat"),
            to: fixture.first.id
        )

        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: tab.id)
        await gate.waitUntilEntered()

        let reopenTask = Task { @MainActor in
            await fixture.state.reopenLastClosedTab()
        }
        await Task.yield()

        fixture.state.archiveWorktree(fixture.first)

        await gate.release()
        await reopenTask.value

        #expect(fixture.state.tabs.tabs(forWorktree: fixture.first.id).isEmpty)
        #expect(fixture.state.selectedWorktreeId != fixture.first.id)
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

    @Test func reopeningManuallyRestoredTerminalDoesNotOpenDuplicateSessions() async {
        var openAttempts = 0
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openAttempts += 1
                return .init(id: "unexpected-session", foregroundPid: { nil })
            }
        )
        let fixture = makeFixture(state: state)
        let tab = TerminalTabState(
            id: "manually-restored-terminal",
            title: "Terminal",
            root: .leaf(PaneLeaf(id: "existing-session", sessionId: "existing-session")),
            focusedLeafId: "existing-session"
        )
        let placement = ClosedTabPlacement(previousID: nil, nextID: nil, ordinal: 0)

        _ = fixture.state.tabs.restore(tab: .terminal(tab), worktreeID: fixture.first.id, placement: placement)
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: tab.id)
        _ = fixture.state.tabs.restore(tab: .terminal(tab), worktreeID: fixture.first.id, placement: placement)
        fixture.state.activateWorktreeCenterTab(worktreeId: fixture.first.id, tabId: tab.id)

        await fixture.state.reopenLastClosedTab()

        #expect(openAttempts == 0)
        #expect(fixture.state.tabs.tabs(forWorktree: fixture.first.id).map(\.id) == [tab.id])
        #expect(fixture.state.tabs.activeTabId(forWorktree: fixture.first.id) == tab.id)
        #expect(!fixture.state.canReopenClosedTab)
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

    @Test func reopeningTerminalDoesNotRestoreAfterWorktreeCleanupDuringRemotePrep() async {
        let gate = AsyncGate()
        var openAttempts = 0
        let state = AppState(
            store: MemoryStore(),
            terminalSessionOpener: { _, _, _, _, _, _, _, _, _ in
                openAttempts += 1
                return .init(id: "unexpected-session", foregroundPid: { nil })
            },
            remoteAccelerationPreparer: { _ in
                await gate.enterAndWait()
            }
        )
        let fixture = makeFixture(state: state)
        let original = TerminalTabState(
            id: "remote-prep-removed-worktree",
            title: "Terminal",
            root: .leaf(PaneLeaf(id: "old-terminal", sessionId: "old-terminal")),
            focusedLeafId: "old-terminal"
        )
        _ = fixture.state.tabs.restore(
            tab: .terminal(original),
            worktreeID: fixture.first.id,
            placement: .init(previousID: nil, nextID: nil, ordinal: 0)
        )
        fixture.state.requestCloseTab(worktreeId: fixture.first.id, tabId: original.id)

        let reopenTask = Task { @MainActor in
            await fixture.state.reopenLastClosedTab()
        }
        await gate.waitUntilEntered()

        fixture.state.archiveWorktree(fixture.first)

        await gate.release()
        await reopenTask.value

        #expect(openAttempts == 0)
        #expect(fixture.state.tabs.tabs(forWorktree: fixture.first.id).isEmpty)
        #expect(fixture.state.selectedWorktreeId != fixture.first.id)
        #expect(!fixture.state.canReopenClosedTab)
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
