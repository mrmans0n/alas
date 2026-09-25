import Foundation
import Observation

struct WorktreeDiffStats: Equatable, Sendable {
    let added: Int
    let deleted: Int
}

struct WorktreeStatusStoreKey: Hashable {
    let projectId: String?
    let path: String
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

    private(set) var statuses: [WorktreeStatusStoreKey: WorktreeDirtyState] = [:]
    private var diffs: [WorktreeStatusStoreKey: WorktreeDiffStats] = [:]

    func diffStats(forPath path: String, projectId: String? = nil) -> WorktreeDiffStats? {
        diffs[WorktreeStatusStoreKey(projectId: projectId, path: path)]
    }

    func applyDiffStats(_ scanned: [String: WorktreeDiffStats], projectId: String? = nil) {
        for (path, stats) in scanned {
            let key = WorktreeStatusStoreKey(projectId: projectId, path: path)
            if diffs[key] != stats { diffs[key] = stats }
        }
    }

    func status(forPath path: String, projectId: String? = nil) -> WorktreeDirtyState {
        statuses[WorktreeStatusStoreKey(projectId: projectId, path: path)] ?? .unknown
    }

    /// Merges a scan's results.
    ///
    /// Merging rather than replacing keeps a partial scan — one project
    /// finished while another is still running, or a remote host skipped
    /// because it is offline — from blanking rows it never covered.
    func apply(_ scanned: [String: WorktreeDirtyState], projectId: String? = nil) {
        guard !scanned.isEmpty else { return }
        var merged = statuses
        for (path, status) in scanned {
            merged[WorktreeStatusStoreKey(projectId: projectId, path: path)] = status
        }
        if merged != statuses { statuses = merged }
    }

    /// Drops entries for worktrees that no longer exist. Value-diffed so a
    /// no-op prune does not invalidate observers.
    func prune(keepingPaths: Set<String>, keepingProjectPaths: Set<WorktreeStatusStoreKey> = []) {
        func shouldKeep(_ key: WorktreeStatusStoreKey) -> Bool {
            if key.projectId == nil { return keepingPaths.contains(key.path) }
            return keepingProjectPaths.contains(key)
        }

        let prunedDiffs = diffs.filter { shouldKeep($0.key) }
        if prunedDiffs.count != diffs.count { diffs = prunedDiffs }
        let pruned = statuses.filter { shouldKeep($0.key) }
        if pruned.count != statuses.count { statuses = pruned }
    }
}
