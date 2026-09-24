import Foundation
import Testing
@testable import Alas

@MainActor
struct RunReportTabTests {
    @Test func outputPresentationKeepsAvailableLogTextAndTruncationState() {
        let presentation = RunReportOutputPresentation.make(
            for: .available(text: "Task :test\nBUILD SUCCESSFUL", truncated: true)
        )

        #expect(presentation == .document(text: "Task :test\nBUILD SUCCESSFUL", isTruncated: true))
    }

    @Test func outputPresentationUsesAnEmptyStateForNoCapturedText() {
        let presentation = RunReportOutputPresentation.make(for: .available(text: "", truncated: false))

        #expect(presentation == .document(text: "No output was produced.", isTruncated: false))
    }

    @Test func outputPresentationDistinguishesUnavailableOutput() {
        #expect(RunReportOutputPresentation.make(for: .unavailable) == .unavailable)
    }

    @Test func tabStateRoundTripsWithStableRunIdentity() throws {
        let state = RunReportTabState(worktreeId: "wt-1", projectId: "project-b", runID: "run-1")
        let tab = Tab.runReport(state)

        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))

        #expect(restored == tab)
        #expect(tab.id == "run-report:run-1")
        #expect(tab.title == "Run Report")
        #expect(tab.isRestorable)
    }

    @Test func transientReportTabsDoNotRestore() throws {
        let state = RunReportTabState(worktreeId: "wt-1", runID: "legacy", isTransient: true)
        let tab = Tab.runReport(state)

        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))

        #expect(restored == tab)
        #expect(!tab.isRestorable)
    }

    @Test func savedReportTabsWithoutTransientFlagDecodeAsRestorable() throws {
        let data = Data("""
        {
          "runReport": {
            "_0": {
              "id": "run-report:run-1",
              "worktreeId": "wt-1",
              "runID": "run-1"
            }
          }
        }
        """.utf8)

        let restored = try JSONDecoder().decode(Tab.self, from: data)

        #expect(restored == .runReport(RunReportTabState(worktreeId: "wt-1", runID: "run-1")))
        #expect(restored.isRestorable)
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

    @Test func closingReportsIsScopedToProjectWhenPathsAreShared() {
        let worktreeID = "run-report-shared-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let manager = TabsManager()
        let projectA = manager.openOrFocusRunReport(worktreeId: worktreeID, projectId: "project-a", runID: "run-a")
        let projectB = manager.openOrFocusRunReport(worktreeId: worktreeID, projectId: "project-b", runID: "run-b")

        manager.closeRunReports(worktreeId: worktreeID, projectId: "project-a")

        #expect(manager.tabs(forWorktree: worktreeID).map(\.id) == [projectB.id])
        guard case .runReport(let report) = projectB else {
            Issue.record("Expected project B's report tab")
            return
        }
        #expect(report.projectId == "project-b")
        #expect(manager.tabs(forWorktree: worktreeID).contains(where: { $0.id == projectA.id }) == false)
    }
}
