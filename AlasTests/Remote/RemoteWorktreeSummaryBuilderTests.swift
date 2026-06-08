import Foundation
import Testing
@testable import Alas

struct RemoteWorktreeSummaryBuilderTests {
    private func worktree() -> Worktree {
        Worktree(
            id: "wt",
            projectId: "p",
            name: "feature-branch",
            branch: "nacho/feature-branch",
            path: URL(fileURLWithPath: "/tmp/alas-feature"),
            status: .dirty,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func availableMetricsSummarizeCommitsUniqueFilesLinesAndConflicts() {
        let summary = RemoteWorktreeSummaryBuilder.make(
            projectName: "alas",
            worktree: worktree(),
            metrics: .available(
                comparisonRef: "origin/main",
                commitCount: 3,
                changes: [
                    ChangedFile(path: "A.swift", status: "M", stage: .staged, add: 10, del: 2, renameFrom: nil),
                    ChangedFile(path: "A.swift", status: "M", stage: .unstaged, add: 1, del: 0, renameFrom: nil),
                    ChangedFile(path: "B.swift", status: "U", stage: .unstaged, add: 4, del: 5, renameFrom: nil, conflict: .bothModified),
                ]
            )
        )

        #expect(summary.projectName == "alas")
        #expect(summary.worktreeName == "feature-branch")
        #expect(summary.branch == "nacho/feature-branch")
        #expect(summary.path == "/tmp/alas-feature")
        #expect(summary.metricsAvailable)
        #expect(summary.comparisonRef == "origin/main")
        #expect(summary.commitCount == 3)
        #expect(summary.changedFileCount == 2)
        #expect(summary.addedLines == 15)
        #expect(summary.deletedLines == 7)
        #expect(summary.conflictCount == 1)
    }

    @Test func unavailableMetricsKeepIdentityAndZeroCounts() {
        let summary = RemoteWorktreeSummaryBuilder.make(
            projectName: "alas",
            worktree: worktree(),
            metrics: .unavailable
        )

        #expect(summary.projectName == "alas")
        #expect(summary.worktreeName == "feature-branch")
        #expect(summary.metricsAvailable == false)
        #expect(summary.comparisonRef == nil)
        #expect(summary.commitCount == 0)
        #expect(summary.changedFileCount == 0)
        #expect(summary.addedLines == 0)
        #expect(summary.deletedLines == 0)
        #expect(summary.conflictCount == 0)
    }
}
