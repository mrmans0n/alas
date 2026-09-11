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
        // Branch names deliberately avoid letters already present in the
        // surrounding prose ("worktrees", "branches", "are removed") so the
        // assertions can only pass if the bullet list is actually populated.
        let model = WorktreeCleanupModel.forTesting(candidates: [
            candidate(branch: "feature-alpha", verdict: .candidate(confidence: .high)),
            candidate(branch: "feature-beta", verdict: .candidate(confidence: .medium)),
        ])
        model.keepBranches = false
        let message = model.confirmationMessage()
        #expect(message.contains("feature-alpha"))
        #expect(message.contains("feature-beta"))
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
    /// pointing at nothing. Candidate "b" is `.dirty` — never in the default
    /// selection — so its survival across the first rescan, and its absence
    /// after the second, can only be explained by real intersection against
    /// the manual selection, not by an implementation that always resets to
    /// `defaultSelection`.
    @Test func rescanDropsSelectedRowsThatDisappeared() {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        let b = candidate(branch: "b", verdict: .dirty)
        let model = WorktreeCleanupModel.forTesting(candidates: [a, b])
        #expect(model.selectedIds == ["/tmp/wt-a"])

        model.toggle("/tmp/wt-b")   // per-item override selects the dirty row
        #expect(model.selectedIds == ["/tmp/wt-a", "/tmp/wt-b"])

        model.applyScanResult([a, b])
        #expect(model.selectedIds == ["/tmp/wt-a", "/tmp/wt-b"])

        model.applyScanResult([a])
        #expect(model.selectedIds == ["/tmp/wt-a"])
    }

    /// Drives a rescan through `runScan()` itself, not `applyScanResult`
    /// directly — this is the entry point the Refresh button and any
    /// production rescan actually use, and `scanState` is `.scanning` for
    /// the duration of the call, which is exactly what broke a prior
    /// implementation that read `scanState` to decide whether to reconcile.
    @Test func runScanThroughItsPublicEntryPointKeepsManualSelection() async {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        let b = candidate(branch: "b", verdict: .candidate(confidence: .high))
        let model = WorktreeCleanupModel(
            projectId: "p",
            keepBranches: false,
            scan: { .success([a, b]) },
            deleteBatch: { _, _, _ in [] },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )
        await model.runScan()
        #expect(model.selectedIds == ["/tmp/wt-a", "/tmp/wt-b"])

        model.toggle("/tmp/wt-a")   // manual deselection, leaving only b
        #expect(model.selectedIds == ["/tmp/wt-b"])

        await model.runScan()       // a real rescan through the public API
        #expect(model.selectedIds == ["/tmp/wt-b"])
    }

    /// Bulk archive tears down tabs, terminals and agent sessions that are not
    /// recreated on restore, so it must prompt exactly like bulk delete does.
    @Test func archiveSelectedIsGatedOnConfirmation() async {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        var confirmCalls: [(title: String, message: String, button: String)] = []
        var archiveBatchCalls = 0
        let model = WorktreeCleanupModel(
            projectId: "p",
            keepBranches: false,
            scan: { .success([a]) },
            deleteBatch: { _, _, _ in [] },
            archiveBatch: { worktrees in
                archiveBatchCalls += 1
                return worktrees.map {
                    WorktreeBatchResult(worktreeId: $0.id, branch: $0.branch, outcome: .archived)
                }
            },
            confirm: { title, message, button in
                confirmCalls.append((title, message, button))
                return false   // decline — nothing should archive
            }
        )
        model.applyScanResult([a])

        await model.archiveSelected()

        #expect(confirmCalls.count == 1)
        #expect(confirmCalls[0].title.contains("Archive"))
        #expect(confirmCalls[0].message.contains("a"))
        #expect(confirmCalls[0].button == "Archive")
        #expect(archiveBatchCalls == 0)
        #expect(model.results.isEmpty)
    }

    @Test func archiveSelectedProceedsWhenConfirmed() async {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        var archiveBatchCalls = 0
        let model = WorktreeCleanupModel(
            projectId: "p",
            keepBranches: false,
            scan: { .success([a]) },
            deleteBatch: { _, _, _ in [] },
            archiveBatch: { worktrees in
                archiveBatchCalls += 1
                return worktrees.map {
                    WorktreeBatchResult(worktreeId: $0.id, branch: $0.branch, outcome: .archived)
                }
            },
            confirm: { _, _, _ in true }
        )
        model.applyScanResult([a])

        await model.archiveSelected()

        #expect(archiveBatchCalls == 1)
    }

    @Test func deleteSelectedIsGatedOnConfirmation() async {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        var deleteBatchCalls = 0
        var confirmButtons: [String] = []
        let model = WorktreeCleanupModel(
            projectId: "p",
            keepBranches: false,
            scan: { .success([a]) },
            deleteBatch: { _, _, _ in
                deleteBatchCalls += 1
                return []
            },
            archiveBatch: { _ in [] },
            confirm: { _, _, button in
                confirmButtons.append(button)
                return false
            }
        )
        model.applyScanResult([a])

        await model.deleteSelected()

        #expect(confirmButtons == ["Delete"])
        #expect(deleteBatchCalls == 0)
    }

    /// Only a high-confidence candidate — the scan matched its exact HEAD SHA
    /// against a confirmed-merged review request — is trusted enough to
    /// force-delete its branch. A selected dirty row overridden by the user,
    /// or a medium/low-confidence match, must not be swept into that set even
    /// though both are part of the same batch.
    @Test func deleteSelectedNamesOnlyHighConfidenceCandidatesAsForgeConfirmed() async {
        let highConfidence = candidate(branch: "a", verdict: .candidate(confidence: .high))
        let mediumConfidence = candidate(branch: "b", verdict: .candidate(confidence: .medium))
        let overriddenDirty = candidate(branch: "c", verdict: .dirty)
        var passedForgeConfirmedIds: Set<String> = []
        let model = WorktreeCleanupModel(
            projectId: "p",
            keepBranches: false,
            scan: { .success([highConfidence, mediumConfidence, overriddenDirty]) },
            deleteBatch: { _, _, forgeConfirmedMergedWorktreeIds in
                passedForgeConfirmedIds = forgeConfirmedMergedWorktreeIds
                return []
            },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )
        model.applyScanResult([highConfidence, mediumConfidence, overriddenDirty])
        model.toggle("/tmp/wt-c")   // per-item override on the dirty row

        await model.deleteSelected()

        #expect(passedForgeConfirmedIds == ["/tmp/wt-a"])
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
