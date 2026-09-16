import Foundation
import Testing
@testable import Alas

@MainActor
struct RunReportTabTests {
    @Test func tabStateRoundTripsWithStableRunIdentity() throws {
        let state = RunReportTabState(worktreeId: "wt-1", runID: "run-1")
        let tab = Tab.runReport(state)

        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))

        #expect(restored == tab)
        #expect(tab.id == "run-report:run-1")
        #expect(tab.title == "Run Report")
        #expect(tab.isRestorable)
    }

    @Test func openingSameReportFocusesOneTab() {
        let worktreeID = "run-report-focus-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let manager = TabsManager()

        let first = manager.openOrFocusRunReport(worktreeId: worktreeID, runID: "run-1")
        let second = manager.openOrFocusRunReport(worktreeId: worktreeID, runID: "run-1")

        #expect(first.id == second.id)
        #expect(manager.tabs(forWorktree: worktreeID).map(\.id) == [first.id])
        #expect(manager.activeTabId(forWorktree: worktreeID) == first.id)
    }

    @Test func closingReportsIsScopedToOwningWorktree() {
        let firstWorktreeID = "run-report-first-\(UUID().uuidString)"
        let secondWorktreeID = "run-report-second-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: firstWorktreeID))
            try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: secondWorktreeID))
        }
        let manager = TabsManager()
        _ = manager.openOrFocusRunReport(worktreeId: firstWorktreeID, runID: "run-1")
        let second = manager.openOrFocusRunReport(worktreeId: secondWorktreeID, runID: "run-2")

        manager.closeRunReports(worktreeId: firstWorktreeID)

        #expect(manager.tabs(forWorktree: firstWorktreeID).isEmpty)
        #expect(manager.tabs(forWorktree: secondWorktreeID).map(\.id) == [second.id])
    }
}
