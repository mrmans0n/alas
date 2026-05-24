import Foundation
import Observation

/// Per-worktree, observable holder for the current in-progress
/// merge/rebase/cherry-pick (or nil when the worktree is idle).
/// Refreshed by `RightPaneState` whenever it refreshes `changes`.
@Observable
final class MergeOperationState {
    private(set) var current: MergeOperation? = nil

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
        } catch {
            // Keep `current` as-is so transient errors don't flap the UI.
            // (Errors are not surfaced in v1; see Plan 2 for an error pill on the OperationCard.)
        }
    }
}
