import Foundation

/// External reads/side effects for the review target palette, injected so
/// the model is unit-testable (same pattern as `RepoSelectorEnvironment`).
struct ReviewTargetPaletteEnvironment {
    var worktrees: () -> [Worktree]
    var currentWorktreeId: () -> String?
    var loadCommitsAhead: (Worktree) async throws -> (commits: [CommitInfo], comparisonRef: String?)
    var loadBranches: (Worktree) async throws -> [String]
    var resolveRevision: (Worktree, String) async throws -> String
    var currentBranch: (Worktree) async throws -> String
    var headSHA: (Worktree) async throws -> String
    /// Opens the review session and closes the palette. The worktree is the
    /// session's host — callers switch the app's active worktree to it.
    var openTarget: (ReviewSessionTarget, Worktree) -> Void
}
