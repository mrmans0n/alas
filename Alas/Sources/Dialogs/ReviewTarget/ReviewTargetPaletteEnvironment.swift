import Foundation

/// External reads/side effects for the review target palette, injected so
/// the model is unit-testable (same pattern as `RepoSelectorEnvironment`).
struct ReviewTargetPaletteEnvironment {
    var worktrees: () -> [Worktree]
    var currentWorktreeId: () -> String?
    /// `@Sendable` because the palette fans these two out concurrently — one
    /// child task per worktree for `loadCommitsAhead`, and an `async let` pair
    /// in `loadTargets`. The live implementations snapshot every MainActor
    /// value they need before the closure is formed.
    var loadCommitsAhead: @Sendable (Worktree) async throws -> (commits: [CommitInfo], comparisonRef: String?)
    var loadBranches: @Sendable (Worktree) async throws -> [String]
    var resolveRevision: (Worktree, String) async throws -> String
    var currentBranch: (Worktree) async throws -> String
    var resolveTrackedRevision: (Worktree, String) async throws -> TrackedRevisionCandidate
    var headSHA: (Worktree) async throws -> String
    /// Opens the review session and closes the palette. The worktree is the
    /// session's host — callers switch the app's active worktree to it.
    var openTarget: (ReviewSessionTarget, Worktree) -> Void
}
