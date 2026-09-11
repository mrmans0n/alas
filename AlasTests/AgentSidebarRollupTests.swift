import Foundation
import Testing
@testable import Alas

@Suite("Agent sidebar rollup")
struct AgentSidebarRollupTests {
    @Test @MainActor
    func liveACPRowOverridesPersistedHistoryAndBindsUsageAndPlan() {
        let session = makeLiveSession(id: "acp-a", worktreeID: "worktree-a")
        session.currentModel = "gpt-5"
        session.contextUsage = ACPUsageInfo(used: 45_000, size: 128_000, cost: nil)
        _ = session.apply(.plan([
            .init(content: "Ship sidebar", status: "completed"),
            .init(content: "Test isolation", status: "in_progress"),
        ]))

        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "acp-a")],
            liveACP: [session], terminalTabs: [], harnessActivity: [:], remoteHost: "builder.example"
        ))

        let row = try! #require(rollup.active.first)
        #expect(row.id == .acp("acp-a"))
        #expect(row.model == "gpt-5")
        #expect(row.contextUsage?.used == 45_000)
        #expect(row.plan == .init(completed: 1, total: 2, currentStep: "Test isolation"))
        #expect(row.host == "builder.example")
    }

    @Test @MainActor
    func builderFiltersOtherWorktreesAndUsesUnknownForUnhookedTerminal() {
        let rollup = AgentSidebarRollupBuilder.build(.init(
            worktreeID: "worktree-a", persistedACP: [makeRow(id: "a")],
            liveACP: [makeLiveSession(id: "b", worktreeID: "worktree-b")],
            terminalTabs: [makeTerminal(id: "terminal-a", sessionID: "shell-a")],
            harnessActivity: [:], remoteHost: nil
        ))

        #expect(rollup.rows.map(\.id) == [.acp("a"), .terminal(tabID: "terminal-a", sessionID: "shell-a")])
        #expect(rollup.rows.last?.state == .unknown)
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
}
