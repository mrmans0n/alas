import Testing
@testable import Alas

struct RightPaneToolbarModelTests {
    private func leading(
        _ tab: RightPaneTab,
        branch: String = "main",
        activeAgentCount: Int = 0,
        waitingAgentCount: Int = 0,
        runningScriptNames: [String] = []
    ) -> String {
        RightPaneToolbarModel.leading(
            for: tab,
            branch: branch,
            activeAgentCount: activeAgentCount,
            waitingAgentCount: waitingAgentCount,
            runningScriptNames: runningScriptNames
        )
    }

    @Test func changesShowsTheCurrentBranch() {
        #expect(leading(.changes, branch: "nacho/sidebar-new-design") == "nacho/sidebar-new-design")
    }

    @Test func changesFallsBackWhenTheBranchIsUnknown() {
        #expect(leading(.changes, branch: "") == "Detached HEAD")
    }

    @Test func filesLabelsTheWorkingTree() {
        #expect(leading(.files) == "Working tree")
    }

    @Test func agentSummarisesActiveAndWaitingCounts() {
        #expect(leading(.agent, activeAgentCount: 2, waitingAgentCount: 1) == "2 active · 1 waiting")
        #expect(leading(.agent, activeAgentCount: 2, waitingAgentCount: 0) == "2 active")
        #expect(leading(.agent, activeAgentCount: 1, waitingAgentCount: 0) == "1 active")
        #expect(leading(.agent, activeAgentCount: 0, waitingAgentCount: 0) == "No agents")
    }

    @Test func runNamesASingleCommandAndCountsSeveral() {
        #expect(leading(.run, runningScriptNames: ["pnpm test"]) == "pnpm test")
        #expect(leading(.run, runningScriptNames: ["pnpm test", "pnpm dev"]) == "2 running")
        #expect(leading(.run, runningScriptNames: []) == "Nothing running")
    }

    @Test func onlyChangesShowsDiffTotals() {
        #expect(RightPaneToolbarModel.trailing(for: .changes, totalAdd: 412, totalDel: 88) == .diffTotals(add: 412, del: 88))
        #expect(RightPaneToolbarModel.trailing(for: .agent, totalAdd: 412, totalDel: 88) == .none)
        #expect(RightPaneToolbarModel.trailing(for: .run, totalAdd: 412, totalDel: 88) == .none)
    }

    @Test func changesHidesTotalsWhenThereIsNoDiff() {
        #expect(RightPaneToolbarModel.trailing(for: .changes, totalAdd: 0, totalDel: 0) == .none)
    }

    @Test func filesOffersSearch() {
        #expect(RightPaneToolbarModel.trailing(for: .files, totalAdd: 0, totalDel: 0) == .search)
    }

    @Test func onlyFilesShowsTheOverflowMenu() {
        #expect(RightPaneToolbarModel.showsOverflowMenu(for: .files))
        #expect(!RightPaneToolbarModel.showsOverflowMenu(for: .changes))
        #expect(!RightPaneToolbarModel.showsOverflowMenu(for: .agent))
        #expect(!RightPaneToolbarModel.showsOverflowMenu(for: .run))
    }
}
