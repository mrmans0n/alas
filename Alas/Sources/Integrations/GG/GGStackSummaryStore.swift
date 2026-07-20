import Foundation
import Observation

/// Worktree path → stack summary, written by each RightPaneState after a
/// stack load and read by the sidebar badge. Phase-1 limitation: only
/// worktrees whose right pane has been activated have a badge.
@MainActor
@Observable
final class GGStackSummaryStore {
    static let shared = GGStackSummaryStore()
    var summaries: [String: GGStackSummary] = [:]

    /// Drops summaries for worktrees that no longer exist. Called after the
    /// app's worktree cleanup pass; value-diffed to avoid invalidating
    /// observers when nothing was pruned.
    func prune(keepingPaths: Set<String>) {
        let pruned = summaries.filter { keepingPaths.contains($0.key) }
        if pruned.count != summaries.count { summaries = pruned }
    }
}
