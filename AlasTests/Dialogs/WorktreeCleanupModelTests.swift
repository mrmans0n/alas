import Testing
import Foundation
@testable import Alas

@MainActor
struct WorktreeCleanupModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(
        branch: String,
        verdict: WorktreeCleanupVerdict,
        signals: [WorktreeCleanupSignal] = []
    ) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            worktree: Worktree(
                id: "/tmp/wt-\(branch)",
                projectId: "p",
                name: branch,
                branch: branch,
                path: URL(fileURLWithPath: "/tmp/wt-\(branch)"),
                isMainWorktree: verdict == .excluded,
                status: .clean,
                lastActivity: now
            ),
            verdict: verdict,
            signals: signals
        )
    }

    @Test func candidatesAreSelectedByDefaultAndOthersAreNot() {
        let candidates = [
            candidate(branch: "a", verdict: .candidate(confidence: .high)),
            candidate(branch: "b", verdict: .dirty),
            candidate(branch: "c", verdict: .busy),
            candidate(branch: "d", verdict: .excluded),
        ]
        let selection = WorktreeCleanupModel.defaultSelection(from: candidates)
        #expect(selection == ["/tmp/wt-a"])
    }

    @Test func togglingSelectsAndDeselectsAnOverridableRow() {
        let model = WorktreeCleanupModel.forTesting(candidates: [
            candidate(branch: "a", verdict: .candidate(confidence: .high)),
            candidate(branch: "b", verdict: .dirty),
        ])
        #expect(model.selectedIds == ["/tmp/wt-a"])

        model.toggle("/tmp/wt-b")
        #expect(model.selectedIds == ["/tmp/wt-a", "/tmp/wt-b"])

        model.toggle("/tmp/wt-a")
        #expect(model.selectedIds == ["/tmp/wt-b"])
    }

    /// Per-item override may select a dirty or busy worktree, but never an
    /// excluded one — that is what keeps bulk delete off a main worktree.
    @Test func excludedRowsCannotBeSelected() {
        let model = WorktreeCleanupModel.forTesting(candidates: [
            candidate(branch: "main", verdict: .excluded, signals: [.mainWorktree]),
        ])
        model.toggle("/tmp/wt-main")
        #expect(model.selectedIds.isEmpty)
    }

    @Test func confirmationNamesEveryWorktreeAndTheBranchPolicy() {
        let model = WorktreeCleanupModel.forTesting(candidates: [
            candidate(branch: "a", verdict: .candidate(confidence: .high)),
            candidate(branch: "b", verdict: .candidate(confidence: .medium)),
        ])
        model.keepBranches = false
        let message = model.confirmationMessage()
        #expect(message.contains("a"))
        #expect(message.contains("b"))
        #expect(message.lowercased().contains("branch"))

        model.keepBranches = true
        #expect(model.confirmationMessage().lowercased().contains("kept"))
    }

    @Test func summaryCountsEachOutcomeKind() {
        let results = [
            WorktreeBatchResult(worktreeId: "1", branch: "a", outcome: .deleted),
            WorktreeBatchResult(worktreeId: "2", branch: "b", outcome: .deleted),
            WorktreeBatchResult(worktreeId: "3", branch: "c", outcome: .failed(message: "boom")),
            WorktreeBatchResult(worktreeId: "4", branch: "d", outcome: .needsForce),
            WorktreeBatchResult(worktreeId: "5", branch: "e", outcome: .skipped(reason: "Main worktree")),
        ]
        let summary = WorktreeCleanupModel.summary(for: results)
        #expect(summary.contains("2 deleted"))
        #expect(summary.contains("1 failed"))
    }

    /// A rescan must not silently undo the user's manual selection.
    @Test func rescanKeepsManualSelectionForRowsThatStillExist() {
        let all = [
            candidate(branch: "a", verdict: .candidate(confidence: .high)),
            candidate(branch: "b", verdict: .candidate(confidence: .high)),
        ]
        let model = WorktreeCleanupModel.forTesting(candidates: all)
        model.toggle("/tmp/wt-a")   // deselect a, leaving b
        #expect(model.selectedIds == ["/tmp/wt-b"])

        model.applyScanResult(all)
        #expect(model.selectedIds == ["/tmp/wt-b"])
    }

    /// Rows that vanished from a rescan — typically because they were just
    /// deleted — must drop out of the selection rather than linger as ids
    /// pointing at nothing.
    @Test func rescanDropsSelectedRowsThatDisappeared() {
        let model = WorktreeCleanupModel.forTesting(candidates: [
            candidate(branch: "a", verdict: .candidate(confidence: .high)),
            candidate(branch: "b", verdict: .candidate(confidence: .high)),
        ])
        #expect(model.selectedIds == ["/tmp/wt-a", "/tmp/wt-b"])

        model.applyScanResult([candidate(branch: "a", verdict: .candidate(confidence: .high))])
        #expect(model.selectedIds == ["/tmp/wt-a"])
    }

    @Test func selectedWorktreesFollowsDisplayOrder() {
        let model = WorktreeCleanupModel.forTesting(candidates: [
            candidate(branch: "a", verdict: .candidate(confidence: .high)),
            candidate(branch: "b", verdict: .candidate(confidence: .high)),
            candidate(branch: "c", verdict: .candidate(confidence: .high)),
        ])
        #expect(model.selectedWorktrees().map(\.branch) == ["a", "b", "c"])
    }
}
