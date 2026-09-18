import Foundation
import Observation

struct WorktreeDiffStats: Equatable, Sendable {
    let added: Int
    let deleted: Int
}

/// Worktree path → working-tree status, written by `WorktreeStatusScanner` and
/// read by the sidebar row.
///
/// Mirrors `GGStackSummaryStore`, with one deliberate difference: that store
/// covers only worktrees whose right pane has been activated, because a missing
/// stack badge merely withholds information. A missing dirty badge reads as
/// "clean", so this store is populated for every worktree.
@MainActor
@Observable
final class WorktreeStatusStore {
    static let shared = WorktreeStatusStore()

    private(set) var statuses: [String: WorktreeDirtyState] = [:]
    private var diffs: [String: WorktreeDiffStats] = [:]

    func diffStats(forPath path: String) -> WorktreeDiffStats? {
        diffs[path]
    }

    func applyDiffStats(_ scanned: [String: WorktreeDiffStats]) {
        for (path, stats) in scanned where diffs[path] != stats {
            diffs[path] = stats
        }
    }

    func status(forPath path: String) -> WorktreeDirtyState {
        statuses[path] ?? .unknown
    }

    /// Merges a scan's results.
    ///
    /// Merging rather than replacing keeps a partial scan — one project
    /// finished while another is still running, or a remote host skipped
    /// because it is offline — from blanking rows it never covered.
    func apply(_ scanned: [String: WorktreeDirtyState]) {
        guard !scanned.isEmpty else { return }
        var merged = statuses
        for (path, status) in scanned { merged[path] = status }
        if merged != statuses { statuses = merged }
    }

    /// Drops entries for worktrees that no longer exist. Value-diffed so a
    /// no-op prune does not invalidate observers.
    func prune(keepingPaths: Set<String>) {
        let prunedDiffs = diffs.filter { keepingPaths.contains($0.key) }
        if prunedDiffs.count != diffs.count { diffs = prunedDiffs }
        let pruned = statuses.filter { keepingPaths.contains($0.key) }
        if pruned.count != statuses.count { statuses = pruned }
    }
}
