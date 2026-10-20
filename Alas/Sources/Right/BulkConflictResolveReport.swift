/// Result of `RightPaneState.resolveAllConflicts(using:)`, delivered when the
/// workspace-level agent run finishes.
struct BulkConflictResolveReport: Equatable {
    /// True when the agent invocation itself succeeded (process exit 0,
    /// no Swift-side error). False on launch failure, timeout, or
    /// cancellation. Doesn't speak to whether every conflict actually
    /// got resolved — check the refreshed conflict count for that.
    let success: Bool
    /// Conflicts remaining after the refresh that followed the run.
    /// Zero means the agent reconciled everything.
    let remainingConflicts: Int
    /// Message shown in the worktree's in-app notification.
    let summary: String
}
