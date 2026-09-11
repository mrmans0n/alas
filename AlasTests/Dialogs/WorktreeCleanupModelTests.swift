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

    @Test func worktreeRowsAreAvailableBeforeTheScanStarts() {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        let b = candidate(branch: "b", verdict: .dirty)
        let worktrees = [a.worktree, b.worktree]
        let model = WorktreeCleanupModel(
            projectId: "p",
            worktrees: worktrees,
            keepBranches: false,
            loadWorktrees: { worktrees },
            scan: { _, _ in .success([a, b]) },
            deleteBatch: { _, _, _ in [] },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )

        #expect(model.rows.map(\.worktree.branch) == ["a", "b"])
        #expect(model.rows.allSatisfy { $0.candidate == nil })
        #expect(!model.isScanning)
    }

    @Test func scanPublishesCompletedRowsWhileOtherRowsAreStillLoading() async {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        let b = candidate(branch: "b", verdict: .dirty)
        let worktrees = [a.worktree, b.worktree]
        let gate = WorktreeCleanupScanGate()
        let model = WorktreeCleanupModel(
            projectId: "p",
            worktrees: worktrees,
            keepBranches: false,
            loadWorktrees: { worktrees },
            scan: { _, onUpdate in
                await onUpdate(.init(candidate: a, completed: 1, total: 2))
                await gate.pause()
                await onUpdate(.init(candidate: b, completed: 2, total: 2))
                return .success([a, b])
            },
            deleteBatch: { _, _, _ in [] },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )

        let scanTask = Task { await model.runScan() }
        await gate.waitUntilPaused()

        #expect(model.isScanning)
        #expect(model.scanProgress == .init(completed: 1, total: 2))
        #expect(model.rows[0].candidate == a)
        #expect(!model.rows[0].isScanning)
        #expect(model.rows[1].candidate == nil)
        #expect(model.rows[1].isScanning)

        await gate.resume()
        await scanTask.value
        #expect(!model.isScanning)
        #expect(model.candidates == [a, b])
    }

    /// Drives a rescan through `runScan()` itself, not `applyScanResult`
    /// directly — this is the entry point the Refresh button and any
    /// production rescan actually use. The model is already marked as scanning
    /// while results arrive, so selection reconciliation must use the durable
    /// completed-scan flag rather than transient loading state.
    @Test func runScanThroughItsPublicEntryPointKeepsManualSelection() async {
        let a = candidate(branch: "a", verdict: .candidate(confidence: .high))
        let b = candidate(branch: "b", verdict: .candidate(confidence: .high))
        let model = WorktreeCleanupModel(
            projectId: "p",
            worktrees: [a.worktree, b.worktree],
            keepBranches: false,
            loadWorktrees: { [a.worktree, b.worktree] },
            scan: { _, _ in .success([a, b]) },
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
            worktrees: [a.worktree],
            keepBranches: false,
            loadWorktrees: { [a.worktree] },
            scan: { _, _ in .success([a]) },
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
            worktrees: [a.worktree],
            keepBranches: false,
            loadWorktrees: { [a.worktree] },
            scan: { _, _ in .success([a]) },
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
            worktrees: [a.worktree],
            keepBranches: false,
            loadWorktrees: { [a.worktree] },
            scan: { _, _ in .success([a]) },
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

    /// A row carrying a `.mergedOnForge` signal — the scan matched its exact
    /// HEAD SHA against a confirmed-merged review request — is trusted
    /// enough to force-delete its branch, regardless of that row's overall
    /// verdict. A selected dirty row with no such signal must not be swept
    /// into that map even though it is part of the same batch. The SHA that
    /// travels along is the exact one carried by the signal.
    @Test func deleteSelectedNamesOnlyForgeConfirmedSelectedCandidates() async {
        let highConfidence = candidate(
            branch: "a",
            verdict: .candidate(confidence: .high),
            signals: [.mergedOnForge(identity: "#1", url: URL(string: "https://example.com/1")!, headSHA: "abc123")]
        )
        let mediumConfidence = candidate(branch: "b", verdict: .candidate(confidence: .medium))
        let overriddenDirty = candidate(branch: "c", verdict: .dirty)
        var passedForgeConfirmedSHAs: [String: String] = [:]
        let model = WorktreeCleanupModel(
            projectId: "p",
            worktrees: [
                highConfidence.worktree,
                mediumConfidence.worktree,
                overriddenDirty.worktree,
            ],
            keepBranches: false,
            loadWorktrees: {
                [
                    highConfidence.worktree,
                    mediumConfidence.worktree,
                    overriddenDirty.worktree,
                ]
            },
            scan: { _, _ in .success([highConfidence, mediumConfidence, overriddenDirty]) },
            deleteBatch: { _, _, forgeConfirmedMergedBranchSHAs in
                passedForgeConfirmedSHAs = forgeConfirmedMergedBranchSHAs
                return []
            },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )
        model.applyScanResult([highConfidence, mediumConfidence, overriddenDirty])
        model.toggle("/tmp/wt-c")   // per-item override on the dirty row

        await model.deleteSelected()

        #expect(passedForgeConfirmedSHAs == ["/tmp/wt-a": "abc123"])
    }

    /// The regression this fix closes: a clean, forge-merged worktree that
    /// is not yet idle carries the same `.mergedOnForge` signal but an
    /// `.active` verdict (not `.candidate(.high)`), and remains manually
    /// selectable. Gating the SHA map on the verdict would drop it here and
    /// fall back to `git branch -d`, which silently fails for a squash or
    /// rebase merge — deriving from each selected row's own signals instead
    /// must still pick it up.
    @Test func deleteSelectedIncludesAManuallySelectedActiveForgeMergedRow() async {
        let activeButForgeMerged = candidate(
            branch: "a",
            verdict: .active,
            signals: [.mergedOnForge(identity: "#7", url: URL(string: "https://example.com/7")!, headSHA: "def456")]
        )
        var passedForgeConfirmedSHAs: [String: String] = [:]
        let model = WorktreeCleanupModel(
            projectId: "p",
            worktrees: [activeButForgeMerged.worktree],
            keepBranches: false,
            loadWorktrees: { [activeButForgeMerged.worktree] },
            scan: { _, _ in .success([activeButForgeMerged]) },
            deleteBatch: { _, _, forgeConfirmedMergedBranchSHAs in
                passedForgeConfirmedSHAs = forgeConfirmedMergedBranchSHAs
                return []
            },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )
        model.applyScanResult([activeButForgeMerged])
        model.toggle("/tmp/wt-a")   // manual override — .active is not selected by default

        await model.deleteSelected()

        #expect(passedForgeConfirmedSHAs == ["/tmp/wt-a": "def456"])
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

private actor WorktreeCleanupScanGate {
    private var isPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
