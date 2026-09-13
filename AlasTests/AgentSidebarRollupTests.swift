import Foundation
import Testing
@testable import Alas

@Suite("Agent sidebar rollup")
struct AgentSidebarRollupTests {
    @Test @MainActor
    func actionsExposeTheRowIdentityAfterHistoryBecomesLive() {
        var focused: [AgentSidebarRowID] = []
        let actions = AgentSidebarActions(
            onFocus: { focused.append($0) }, onInterrupt: { _ in },
            onFollowUp: { _, _ in }, onDelegate: nil
        )
        let history = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "acp-a")],
            liveACP: [], terminalTabs: [], harnessActivity: [:], remoteHost: nil
        ))
        let live = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "acp-a")],
            liveACP: [makeLiveSession(id: "acp-a", worktreeID: "worktree-a")],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil
        ))

        actions.onFocus(history.rows[0].id)
        actions.onFocus(live.rows[0].id)

        #expect(focused == [.acp("acp-a"), .acp("acp-a")])
    }

    @Test @MainActor
    func liveACPRowOverridesPersistedHistoryAndBindsUsageAndPlan() {
        let session = makeLiveSession(id: "acp-a", worktreeID: "worktree-a")
        session.currentModel = "gpt-5"
        session.contextUsage = ACPUsageInfo(used: 45_000, size: 128_000, cost: nil)
        _ = session.apply(.plan([
            .init(content: "Ship sidebar", priority: nil, status: "completed"),
            .init(content: "Test isolation", priority: nil, status: "in_progress"),
        ]))

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "acp-a")],
            liveACP: [session], terminalTabs: [], harnessActivity: [:], remoteHost: "builder.example"
        ))

        let row = try! #require(rollup.active.first)
        #expect(row.id == .acp("acp-a"))
        #expect(row.model == "GPT 5")
        #expect(row.contextUsage?.used == 45_000)
        #expect(row.plan == .init(completed: 1, total: 2, currentStep: "Test isolation"))
        #expect(row.host == "builder.example")
    }

    @Test @MainActor
    func disconnectedLiveSessionUsesThePersistedRowsLastActivityNotItsOwnCreationTime() {
        let session = makeLiveSession(id: "acp-a", worktreeID: "worktree-a")
        session.agentState = .disconnected

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a",
            persistedACP: [makeRow(id: "acp-a")],
            liveACP: [session], terminalTabs: [], harnessActivity: [:], remoteHost: nil
        ))

        let row = try! #require(rollup.history.first)
        #expect(row.state == .detached)
        #expect(row.activityAt == Date(timeIntervalSince1970: 2))
    }

    @Test @MainActor
    func builderFiltersOtherWorktreesAndUsesUnknownForUnhookedTerminal() {
        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "a")],
            liveACP: [makeLiveSession(id: "b", worktreeID: "worktree-b")],
            terminalTabs: [makeTerminal(id: "terminal-a", sessionID: "shell-a")],
            harnessActivity: [:], remoteHost: "builder.example"
        ))

        #expect(rollup.rows.map(\.id) == [.acp("a"), .terminal(tabID: "terminal-a", sessionID: "shell-a")])
        #expect(rollup.rows.last?.state == .unknown)
        #expect(rollup.rows.map(\.host) == ["builder.example", "builder.example"])
    }

    @Test @MainActor
    func hookStateOverridesTerminalFallbackAndActionsKeepExactTargets() {
        let activity = HarnessService.HarnessActivityState(
            agent: .codex, state: .permissionRequest, pid: nil, lastBody: nil, updatedAt: .now
        )
        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [],
            terminalTabs: [makeTerminal(id: "terminal-a", sessionID: "shell-a")],
            harnessActivity: ["shell-a": activity], remoteHost: nil
        ))

        let row = try! #require(rollup.rows.first)
        #expect(row.state == .permissionRequest)
        #expect(row.id == .terminal(tabID: "terminal-a", sessionID: "shell-a"))
    }

    @Test @MainActor
    func splitTerminalTabEmitsRowsForEveryLeafWithFocusedLeafFirst() {
        let terminal = TerminalTabState(
            id: "terminal-a",
            title: "Terminal",
            root: .split(PaneSplit(
                id: "split",
                axis: .vertical,
                fraction: 0.5,
                children: [
                    .leaf(PaneLeaf(id: "left-leaf", sessionId: "left-session", lastCwd: nil)),
                    .leaf(PaneLeaf(id: "right-leaf", sessionId: "right-session", lastCwd: nil)),
                ]
            )),
            focusedLeafId: "right-leaf"
        )
        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [],
            terminalTabs: [terminal],
            harnessActivity: [
                "left-session": .init(agent: .claude, state: .busy, pid: nil, lastBody: nil, updatedAt: .now),
                "right-session": .init(agent: .codex, state: .awaitingInput, pid: nil, lastBody: nil, updatedAt: .now),
            ],
            remoteHost: nil
        ))

        #expect(rollup.rows.map(\.id) == [
            .terminal(tabID: "terminal-a", sessionID: "right-session"),
            .terminal(tabID: "terminal-a", sessionID: "left-session"),
        ])
        #expect(rollup.rows.map(\.state) == [.awaitingInput, .running])
        #expect(rollup.rows.map(\.agentID) == ["codex", "claude"])
    }

    @Test @MainActor
    func delegatedChildrenNestUnderTheirParentWithinTheSameSection() {
        let parent = makeLiveSession(id: "parent", worktreeID: "worktree-a")
        let first = makeLiveSession(id: "child-1", worktreeID: "worktree-a")
        let second = makeLiveSession(id: "child-2", worktreeID: "worktree-a")

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [first, parent, second],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil,
            delegatedParents: ["child-1": "parent", "child-2": "parent"]
        ))

        #expect(rollup.rows.map(\.id) == [.acp("parent"), .acp("child-1"), .acp("child-2")])
        #expect(rollup.rows[0].delegation == .parent(childCount: 2))
        #expect(rollup.rows[1].delegation == .child(parentID: "parent", parentTitle: "Session parent", isNested: true))
        #expect(rollup.rows[2].delegation == .child(parentID: "parent", parentTitle: "Session parent", isNested: true))
    }

    @Test @MainActor
    func childKeepsTopLevelPlacementWhenItsParentSitsInTheOtherSection() {
        let child = makeLiveSession(id: "child-1", worktreeID: "worktree-a")

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "parent")], liveACP: [child],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil,
            delegatedParents: ["child-1": "parent"]
        ))

        #expect(rollup.active.map(\.id) == [.acp("child-1")])
        #expect(rollup.history.map(\.id) == [.acp("parent")])
        #expect(rollup.active[0].delegation == .child(parentID: "parent", parentTitle: "Session parent", isNested: false))
        #expect(rollup.history[0].delegation == .parent(childCount: 1))
    }

    @Test @MainActor
    func childWhoseParentIsNotInThisWorktreeFallsBackToAnUntitledCaption() {
        let child = makeLiveSession(id: "child-1", worktreeID: "worktree-a")

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [child],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil,
            delegatedParents: ["child-1": "parent-elsewhere"]
        ))

        #expect(rollup.rows.map(\.id) == [.acp("child-1")])
        #expect(rollup.rows[0].delegation == .child(parentID: "parent-elsewhere", parentTitle: nil, isNested: false))
    }

    @Test @MainActor
    func liveChildReplacingItsPersistedRowNestsExactlyOnce() {
        let parent = makeLiveSession(id: "parent", worktreeID: "worktree-a")
        let child = makeLiveSession(id: "child-1", worktreeID: "worktree-a")

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a",
            persistedACP: [makeRow(id: "parent"), makeRow(id: "child-1")],
            liveACP: [parent, child],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil,
            delegatedParents: ["child-1": "parent"]
        ))

        #expect(rollup.rows.map(\.id) == [.acp("parent"), .acp("child-1")])
        #expect(rollup.rows[0].delegation == .parent(childCount: 1))
    }

    @Test @MainActor
    func mutuallyReferentialDelegationsStayFlatAndKeepEveryRow() {
        let first = makeLiveSession(id: "a", worktreeID: "worktree-a")
        let second = makeLiveSession(id: "b", worktreeID: "worktree-a")

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [first, second],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil,
            delegatedParents: ["a": "b", "b": "a"]
        ))

        #expect(rollup.rows.map(\.id) == [.acp("a"), .acp("b")])
        #expect(rollup.rows.allSatisfy { $0.delegation?.isNestedChild == false })
    }

    @Test @MainActor
    func terminalRowsAreNeverAnnotatedWithDelegation() {
        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [],
            terminalTabs: [makeTerminal(id: "terminal-a", sessionID: "shell-a")],
            harnessActivity: [:], remoteHost: nil,
            delegatedParents: ["shell-a": "parent"]
        ))

        #expect(rollup.rows.map(\.delegation) == [nil])
    }

    @MainActor
    private func makeLiveSession(id: String, worktreeID: String) -> ACPSession {
        ACPSession(id: id, agentId: "codex", worktreeId: worktreeID, title: "Session \(id)")
    }

    private func makeRow(id: String) -> ACPSessionRow {
        ACPSessionRow(
            id: id,
            agentId: "codex",
            title: "Session \(id)",
            currentModel: "persisted-model",
            currentMode: nil,
            autoRun: false,
            createdAt: 1,
            updatedAt: 2,
            lastOpenedAt: 3,
            archived: false
        )
    }

    private func makeTerminal(id: TabID, sessionID: String) -> TerminalTabState {
        TerminalTabState(id: id, title: "Terminal \(id)", sessionId: sessionID)
    }

    @Test @MainActor
    func snapshotKeepsPersistedRowsInTheirOwningWorktree() async throws {
        let (state, first, second) = makeAppFixture()
        let firstManager = try #require(state.acpManager(for: first))
        let secondManager = try #require(state.acpManager(for: second))
        let session = firstManager.createSession(id: "first-session", agentId: "sidebar-test-agent")
        _ = secondManager.createSession(id: "second-session", agentId: "sidebar-test-agent")
        await firstManager.flushAllPersistence()
        firstManager.closeSession(id: session.id)
        await firstManager.refreshRecentNow()
        let terminal = state.tabs.appendTerminal(worktreeId: first.id, title: "First", sessionId: "shell-a")
        state.tabs.appendTerminal(worktreeId: second.id, title: "Second", sessionId: "shell-b")

        let rollup = state.agentSidebarRollup(for: first)

        #expect(rollup.rows.map(\.id) == [.acp("first-session"), .terminal(tabID: terminal.id, sessionID: "shell-a")])
        #expect(rollup.history.map(\.id) == [.acp("first-session")])
    }

    @Test @MainActor
    func focusReopensHistoryInItsWorktreeAndReusesTheNewTab() async throws {
        let (state, first, second) = makeAppFixture()
        let manager = try #require(state.acpManager(for: first))
        let session = manager.createSession(id: "reopened-session", agentId: "sidebar-test-agent")
        await manager.flushAllPersistence()
        manager.closeSession(id: session.id)
        await manager.refreshRecentNow()
        state.selectWorktree(id: second.id)

        await state.focusAgentSidebarRow(.acp("reopened-session"), in: first)
        let reopenedID = try #require(state.tabs.activeTabId(forWorktree: first.id))
        await state.focusAgentSidebarRow(.acp("reopened-session"), in: first)

        #expect(state.tabs.tabs(forWorktree: first.id).count == 1)
        #expect(state.tabs.activeTabId(forWorktree: first.id) == reopenedID)
        #expect(state.tabs.tabs(forWorktree: second.id).isEmpty)
        #expect(state.selectedWorktreeId == first.id)
    }

    @Test @MainActor
    func terminalFocusUsesExactTabAndRejectsOtherWorktreeRows() async {
        let (state, first, second) = makeAppFixture()
        let terminal = state.tabs.appendTerminal(worktreeId: first.id, title: "First", sessionId: "shell-a")
        state.tabs.appendTerminal(worktreeId: first.id, title: "Second", sessionId: "shell-b")
        state.selectWorktree(id: second.id)

        await state.focusAgentSidebarRow(.terminal(tabID: terminal.id, sessionID: "shell-a"), in: first)
        #expect(state.tabs.activeTabId(forWorktree: first.id) == terminal.id)
        await state.focusAgentSidebarRow(.terminal(tabID: terminal.id, sessionID: "shell-a"), in: second)
        #expect(state.tabs.activeTabId(forWorktree: second.id) == nil)
        #expect(state.selectedWorktreeId == first.id)
    }

    @Test @MainActor
    func terminalFocusTargetsLeafSessionAndRejectsStaleRows() async {
        let (state, first, _) = makeAppFixture()
        let terminal = state.tabs.appendTerminal(worktreeId: first.id, title: "Split", sessionId: "left-session")
        _ = state.tabs.splitFocusedLeaf(
            worktreeId: first.id,
            tabId: terminal.id,
            axis: .vertical,
            newLeafId: "right-session",
            newSessionId: "right-session"
        )

        await state.focusAgentSidebarRow(.terminal(tabID: terminal.id, sessionID: "left-session"), in: first)
        let focusedLeft = try! #require(state.tabs.tabs(forWorktree: first.id).compactMap { tab -> String? in
            guard tab.id == terminal.id, case .terminal(let terminal) = tab else { return nil }
            return terminal.focusedLeafId
        }.first)
        #expect(focusedLeft == "left-session")

        await state.focusAgentSidebarRow(.terminal(tabID: terminal.id, sessionID: "missing-session"), in: first)
        let focusedAfterStaleAction = try! #require(state.tabs.tabs(forWorktree: first.id).compactMap { tab -> String? in
            guard tab.id == terminal.id, case .terminal(let terminal) = tab else { return nil }
            return terminal.focusedLeafId
        }.first)
        #expect(focusedAfterStaleAction == "left-session")
    }

    @Test @MainActor
    func sidebarPlanUsesExistingPendingAndCompletedStepSemantics() {
        let session = makeLiveSession(id: "acp-a", worktreeID: "worktree-a")
        _ = session.apply(.plan([.init(content: "Pending task", priority: nil, status: "pending")]))
        let pending = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [session],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil
        ))
        #expect(pending.rows.first?.plan?.currentStep == "Pending task")
        _ = session.apply(.plan([.init(content: "Pending task", priority: nil, status: "completed")]))
        let completed = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [], liveACP: [session],
            terminalTabs: [], harnessActivity: [:], remoteHost: nil
        ))
        #expect(completed.rows.first?.plan?.currentStep == "All steps complete")
    }

    @Test @MainActor
    func followUpTargetsItsWorktreeSessionWhenAnotherTabIsActive() async throws {
        let (state, first, second) = makeAppFixture()
        let firstManager = try #require(state.acpManager(for: first))
        let secondManager = try #require(state.acpManager(for: second))
        let target = firstManager.createSession(id: "shared-session-id", agentId: "sidebar-test-agent")
        let other = secondManager.createSession(id: "shared-session-id", agentId: "sidebar-test-agent")
        target.agentState = .spawning
        other.agentState = .spawning
        #expect(await firstManager.acquireWriterLease(sessionId: target.id))
        #expect(await secondManager.acquireWriterLease(sessionId: other.id))
        state.tabs.append(acpSession: ACPSessionTabState(sessionId: other.id, title: "Other"), to: second.id)
        state.selectWorktree(id: second.id)

        let accepted = await withCheckedContinuation { continuation in
            Task { @MainActor in
                await state.sendPrompt(for: target.id, worktreeID: first.id, text: "Continue here", attachments: []) {
                    continuation.resume(returning: $0)
                }
            }
        }

        #expect(accepted)
        #expect(target.queue.first?.blocks == [.text("Continue here")])
        #expect(other.queue.isEmpty)
        #expect(state.selectedWorktreeId == second.id)
        await firstManager.releaseWriterLease(sessionId: target.id)
        await secondManager.releaseWriterLease(sessionId: other.id)
    }

    @Test @MainActor
    func followUpRefusalReportsFailureWithoutChangingTheQueue() async throws {
        let (state, first, _) = makeAppFixture()
        let manager = try #require(state.acpManager(for: first))
        let target = manager.createSession(id: "read-only-session", agentId: "sidebar-test-agent")
        var accepted: Bool?

        await state.sendPrompt(for: target.id, worktreeID: first.id, text: "Keep this draft", attachments: []) {
            accepted = $0
        }

        #expect(accepted == false)
        #expect(target.queue.isEmpty)
    }

    @Test @MainActor
    func unsentFollowUpSurvivesWorktreeNavigationWithoutLeakingToMatchingSessionID() {
        let (state, first, second) = makeAppFixture()
        state.selectWorktree(id: first.id)
        state.agentSidebarFollowUps[first.id, default: [:]]["same-id"] = .init(text: "Unsent draft")
        state.selectWorktree(id: second.id)
        state.agentSidebarFollowUps[second.id, default: [:]]["same-id"] = .init(text: "Other worktree")
        state.selectWorktree(id: first.id)

        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.text == "Unsent draft")
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.delivery == nil)
        #expect(state.agentSidebarFollowUps[second.id]?["same-id"]?.text == "Other worktree")
    }

    @Test @MainActor
    func pendingAndFailedFollowUpSurviveNavigationUntilDeliverySucceeds() throws {
        let (state, first, second) = makeAppFixture()
        state.selectWorktree(id: first.id)
        let complete = try #require(state.beginAgentSidebarFollowUp(
            for: "same-id", worktreeID: first.id, text: "Keep this after failure"
        ))
        state.selectWorktree(id: second.id)
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.text == "Keep this after failure")
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.delivery == .sending)
        #expect(state.agentSidebarFollowUps[second.id]?["same-id"] == nil)

        complete(false)
        state.selectWorktree(id: first.id)
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.text == "Keep this after failure")
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.delivery == .failed)

        let completeRetry = try #require(state.beginAgentSidebarFollowUp(
            for: "same-id", worktreeID: first.id, text: "Keep this after failure"
        ))
        state.selectWorktree(id: second.id)
        completeRetry(true)
        state.selectWorktree(id: first.id)
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.text == "")
        #expect(state.agentSidebarFollowUps[first.id]?["same-id"]?.delivery == .sent)
    }

    @Test @MainActor
    func pendingFollowUpRejectsDuplicateSubmissionAndPreservesItsDraft() throws {
        let (state, first, _) = makeAppFixture()
        _ = try #require(state.beginAgentSidebarFollowUp(for: "session", worktreeID: first.id, text: "Original"))

        let duplicate = state.beginAgentSidebarFollowUp(for: "session", worktreeID: first.id, text: "Replacement")

        #expect(duplicate == nil)
        #expect(state.agentSidebarFollowUps[first.id]?["session"]?.text == "Original")
        #expect(state.agentSidebarFollowUps[first.id]?["session"]?.delivery == .sending)
    }

    @Test @MainActor
    func recreatingAgentPaneRestoresPendingDraftAndLaterFailure() throws {
        let (state, worktree, _) = makeAppFixture()
        let manager = try #require(state.acpManager(for: worktree))
        var pane: AgentWorktreeTabView? = AgentWorktreeTabView(state: state, worktree: worktree, manager: manager)
        pane?.followUps.wrappedValue["session"] = .init(text: "Draft from the row")
        let complete = try #require(state.beginAgentSidebarFollowUp(
            for: "session", worktreeID: worktree.id, text: "Draft from the row"
        ))

        pane = nil
        pane = AgentWorktreeTabView(state: state, worktree: worktree, manager: manager)
        #expect(pane?.followUps.wrappedValue["session"]?.text == "Draft from the row")
        #expect(pane?.followUps.wrappedValue["session"]?.delivery == .sending)

        pane = nil
        complete(false)
        pane = AgentWorktreeTabView(state: state, worktree: worktree, manager: manager)
        #expect(pane?.followUps.wrappedValue["session"]?.text == "Draft from the row")
        #expect(pane?.followUps.wrappedValue["session"]?.delivery == .failed)
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @MainActor
    private func makeAppFixture() -> (AppState, Worktree, Worktree) {
        let state = AppState(store: MemoryStore())
        let fixtureID = UUID().uuidString
        let project = ProjectConfig(
            id: fixtureID, name: "Agent Sidebar", path: "/tmp/\(fixtureID)",
            color: "blue", addedAt: .distantPast
        )
        let worktrees = ["first", "second"].map { name in
            Worktree(
                id: "\(fixtureID)-\(name)", projectId: fixtureID, name: name, branch: name,
                path: URL(fileURLWithPath: "/tmp/\(fixtureID)/\(name)"),
                status: .clean, lastActivity: .distantPast
            )
        }
        state.projectsManager = ProjectsManager(persistedProjects: [project])
        for worktree in worktrees { state.projectsManager.insertOptimisticWorktree(worktree) }
        return (state, worktrees[0], worktrees[1])
    }
}
