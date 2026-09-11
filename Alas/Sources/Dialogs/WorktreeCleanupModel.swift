import Foundation

struct WorktreeCleanupScanProgress: Equatable {
    let completed: Int
    let total: Int
}

struct WorktreeCleanupRowState: Identifiable, Equatable {
    let worktree: Worktree
    var candidate: WorktreeCleanupCandidate?
    var isScanning: Bool

    var id: String { worktree.id }
}

/// Drives the cleanup sheet: runs scans, tracks selection and per-item results.
/// Everything here is deliberately view-free so the selection and confirmation
/// rules can be tested without rendering.
@MainActor
@Observable
final class WorktreeCleanupModel {
    let projectId: String
    private(set) var rows: [WorktreeCleanupRowState]
    private(set) var selectedIds: Set<String> = []
    private(set) var results: [WorktreeBatchResult] = []
    private(set) var isRunning = false
    private(set) var isScanning = false
    private(set) var scanProgress: WorktreeCleanupScanProgress?
    private(set) var scanError: String?
    var keepBranches: Bool

    private let loadWorktrees: () -> [Worktree]
    private let scan: @Sendable (
        [Worktree],
        @escaping @Sendable (WorktreeCleanupScanUpdate) async -> Void
    ) async -> Result<[WorktreeCleanupCandidate], Error>
    private let deleteBatch: ([Worktree], Bool) async -> [WorktreeBatchResult]
    private let archiveBatch: ([Worktree]) -> [WorktreeBatchResult]
    /// `(title, message, confirmButtonTitle) -> confirmed`. The button title is
    /// passed in because both destructive batch actions route through the same
    /// prompt, and an archive confirmation must not offer a "Delete" button.
    private let confirm: (String, String, String) -> Bool
    /// Tracks whether a scan has ever completed, independent of the transient
    /// loading state, so rescans preserve manual selection while the first
    /// successful scan seeds the default selection.
    private var hasCompletedAScan = false

    init(
        projectId: String,
        worktrees: [Worktree],
        keepBranches: Bool,
        loadWorktrees: @escaping () -> [Worktree],
        scan: @escaping @Sendable (
            [Worktree],
            @escaping @Sendable (WorktreeCleanupScanUpdate) async -> Void
        ) async -> Result<[WorktreeCleanupCandidate], Error>,
        deleteBatch: @escaping ([Worktree], Bool) async -> [WorktreeBatchResult],
        archiveBatch: @escaping ([Worktree]) -> [WorktreeBatchResult],
        confirm: @escaping (String, String, String) -> Bool
    ) {
        self.projectId = projectId
        self.rows = worktrees.map {
            WorktreeCleanupRowState(worktree: $0, candidate: nil, isScanning: false)
        }
        self.keepBranches = keepBranches
        self.loadWorktrees = loadWorktrees
        self.scan = scan
        self.deleteBatch = deleteBatch
        self.archiveBatch = archiveBatch
        self.confirm = confirm
    }

    var candidates: [WorktreeCleanupCandidate] {
        rows.compactMap(\.candidate)
    }

    func runScan() async {
        guard !isScanning else { return }

        let worktrees = loadWorktrees()
        let previousCandidates = Dictionary(
            uniqueKeysWithValues: rows.compactMap { row in
                row.candidate.map { (row.id, $0) }
            }
        )
        rows = worktrees.map { worktree in
            WorktreeCleanupRowState(
                worktree: worktree,
                candidate: previousCandidates[worktree.id],
                isScanning: true
            )
        }
        isScanning = true
        scanProgress = .init(completed: 0, total: worktrees.count)
        scanError = nil

        switch await scan(worktrees, { [weak self] update in
            await self?.applyScanUpdate(update)
        }) {
        case .success(let candidates):
            applyScanResult(candidates)
        case .failure(let error):
            isScanning = false
            scanProgress = nil
            scanError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            for index in rows.indices {
                rows[index].isScanning = false
            }
        }
    }

    /// User-triggered rescan — the sheet's Refresh button, and the initial
    /// load. Clears any results from a prior batch action, since starting a
    /// fresh manual scan means the user is done reviewing that outcome.
    func refresh() async {
        guard !isScanning else { return }
        results = []
        await runScan()
    }

    private func applyScanUpdate(_ update: WorktreeCleanupScanUpdate) {
        guard isScanning,
              let index = rows.firstIndex(where: { $0.id == update.candidate.id })
        else { return }
        rows[index].candidate = update.candidate
        rows[index].isScanning = false
        scanProgress = .init(completed: update.completed, total: update.total)
    }

    /// Applies a fresh scan. If a scan has completed before, keeps any manual
    /// selection that still refers to a row present in the new result and is
    /// still selectable, and drops rows that disappeared or are no longer
    /// selectable — it never auto-selects newly-qualifying rows. Otherwise
    /// (the very first scan) seeds the default selection.
    func applyScanResult(_ candidates: [WorktreeCleanupCandidate]) {
        let previousSelection = selectedIds
        let hadResults = hasCompletedAScan
        rows = candidates.map {
            WorktreeCleanupRowState(worktree: $0.worktree, candidate: $0, isScanning: false)
        }
        isScanning = false
        scanProgress = nil
        scanError = nil
        hasCompletedAScan = true
        if hadResults {
            let selectable = Set(candidates.filter(\.isSelectable).map(\.id))
            selectedIds = previousSelection.intersection(selectable)
        } else {
            selectedIds = Self.defaultSelection(from: candidates)
        }
    }

    static func defaultSelection(
        from candidates: [WorktreeCleanupCandidate]
    ) -> Set<String> {
        Set(candidates.filter(\.isSelectedByDefault).map(\.id))
    }

    /// Per-item override. Excluded rows never become selectable, which is what
    /// keeps a main or remote worktree out of any batch.
    func toggle(_ id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }),
              candidate.isSelectable
        else { return }
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// Selected worktrees in display order, so results read in the same order
    /// as the list the user was looking at.
    func selectedWorktrees() -> [Worktree] {
        candidates
            .filter { selectedIds.contains($0.id) }
            .map(\.worktree)
    }

    func confirmationMessage() -> String {
        let branches = selectedWorktrees().map(\.branch)
        let list = branches.map { "• \($0)" }.joined(separator: "\n")
        let branchPolicy = keepBranches
            ? "Local branches will be kept."
            : "Local branches will be deleted if merged."
        return """
        These worktrees will be removed from disk:

        \(list)

        \(branchPolicy)
        """
    }

    /// Archive-flavoured counterpart to `confirmationMessage()`: nothing is
    /// removed from disk and no branch policy applies, but the tabs, terminals
    /// and agent sessions of every archived worktree are torn down and are not
    /// recreated when it is restored.
    func archiveConfirmationMessage() -> String {
        let branches = selectedWorktrees().map(\.branch)
        let list = branches.map { "• \($0)" }.joined(separator: "\n")
        return """
        These worktrees will be hidden from the sidebar. Their files stay on \
        disk and can be restored later, but open terminals and agent sessions \
        will be closed:

        \(list)
        """
    }

    func deleteSelected() async {
        let targets = selectedWorktrees()
        guard !targets.isEmpty, !isRunning else { return }
        guard confirm(
            "Delete \(targets.count) \(targets.count == 1 ? "worktree" : "worktrees")?",
            confirmationMessage(),
            "Delete"
        ) else { return }

        isRunning = true
        results = await deleteBatch(targets, keepBranches)
        isRunning = false
        await runScan()
    }

    func archiveSelected() async {
        let targets = selectedWorktrees()
        guard !targets.isEmpty, !isRunning else { return }
        guard confirm(
            "Archive \(targets.count) \(targets.count == 1 ? "worktree" : "worktrees")?",
            archiveConfirmationMessage(),
            "Archive"
        ) else { return }

        isRunning = true
        results = archiveBatch(targets)
        isRunning = false
        await runScan()
    }

    static func summary(for results: [WorktreeBatchResult]) -> String {
        var deleted = 0, archived = 0, failed = 0, needsForce = 0, skipped = 0
        for result in results {
            switch result.outcome {
            case .deleted:    deleted += 1
            case .archived:   archived += 1
            case .failed:     failed += 1
            case .needsForce: needsForce += 1
            case .skipped:    skipped += 1
            }
        }
        var parts: [String] = []
        if deleted > 0 { parts.append("\(deleted) deleted") }
        if archived > 0 { parts.append("\(archived) archived") }
        if failed > 0 { parts.append("\(failed) failed") }
        if needsForce > 0 { parts.append("\(needsForce) need force delete") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ")
    }
}

#if DEBUG
extension WorktreeCleanupModel {
    /// Seeds a model with fixed candidates, bypassing scanning.
    static func forTesting(
        candidates: [WorktreeCleanupCandidate]
    ) -> WorktreeCleanupModel {
        let worktrees = candidates.map(\.worktree)
        let model = WorktreeCleanupModel(
            projectId: "p",
            worktrees: worktrees,
            keepBranches: false,
            loadWorktrees: { worktrees },
            scan: { _, _ in .success(candidates) },
            deleteBatch: { _, _ in [] },
            archiveBatch: { _ in [] },
            confirm: { _, _, _ in true }
        )
        model.applyScanResult(candidates)
        return model
    }
}
#endif
