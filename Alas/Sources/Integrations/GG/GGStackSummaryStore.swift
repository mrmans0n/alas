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
}
