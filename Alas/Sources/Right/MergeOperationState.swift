import Foundation
import Observation

/// Per-worktree, observable holder for the current in-progress
/// merge/rebase/cherry-pick (or nil when the worktree is idle).
/// Refreshed by `RightPaneState` whenever it refreshes `changes`.
@Observable
final class MergeOperationState {
    private(set) var current: MergeOperation? = nil
    /// Set when the most recent `refresh()` failed; surfaced in the UI as
    /// a non-fatal warning. Cleared on the next successful refresh.
    private(set) var lastError: String? = nil

    private let worktreePath: URL
    private let gitService: GitService

    init(worktreePath: URL, gitService: GitService) {
        self.worktreePath = worktreePath
        self.gitService = gitService
    }

    /// Re-reads .git marker files and updates `current`. Safe to call
    /// frequently — only inspects local files (no network).
    func refresh() async {
        do {
            current = try await gitService.mergeState(worktreePath: worktreePath)
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // Keep `current` as-is so transient errors don't flap the UI.
        }
    }
}
