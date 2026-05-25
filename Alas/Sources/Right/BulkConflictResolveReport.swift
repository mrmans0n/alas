import Foundation

/// Result of `RightPaneState.resolveAllConflicts(using:)`. Surfaced in
/// the Conflicts section as a transient banner after the agent's
/// workspace-level run finishes. The actual "did it work?" signal is
/// the post-refresh conflict count — this banner just lets the user
/// see the agent's narrative for what it did.
struct BulkConflictResolveReport: Equatable {
    /// True when the agent invocation itself succeeded (process exit 0,
    /// no Swift-side error). False on launch failure, timeout, or
    /// cancellation. Doesn't speak to whether every conflict actually
    /// got resolved — check the refreshed conflict count for that.
    let success: Bool
    /// Conflicts remaining after the refresh that followed the run.
    /// Zero means the agent reconciled everything.
    let remainingConflicts: Int
    /// Subject line from the agent's stdout, surfaced as the banner
    /// headline. Empty when the agent produced no usable output.
    let summary: String
    /// Optional full body, shown in the banner tooltip.
    let details: String
}
