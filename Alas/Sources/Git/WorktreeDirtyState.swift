import Foundation

/// Working-tree cleanliness for one worktree.
///
/// Derived, and deliberately never persisted. `Worktree.status` is a persisted
/// field that was written once at construction and never updated, which is why
/// the sidebar cannot trust it; this type exists so that mistake is not
/// repeated. Recompute it — do not store it.
///
/// Named to avoid colliding with the legacy `WorktreeStatus` in `GitTypes.swift`, the persisted-and-never-updated enum this type replaces in practice.
enum WorktreeDirtyState: Equatable, Sendable {
    /// No scan has completed for this worktree yet.
    ///
    /// Renders identically to `clean` (nothing at all), but must stay a
    /// distinct case: collapsing the two would make the first paint after
    /// launch assert that every worktree is clean before anything had looked.
    case unknown

    case clean

    /// `conflictCount` is a subset of `fileCount` — an unmerged path is also a
    /// changed path, and `git status` reports it once.
    case dirty(fileCount: Int, conflictCount: Int)
}
