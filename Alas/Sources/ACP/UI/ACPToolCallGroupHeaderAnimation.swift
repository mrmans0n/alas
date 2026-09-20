import Foundation

/// Animation policy for `ACPToolCallGroupHeaderRow`. Pure, so the decision
/// can be tested without standing up SwiftUI — same shape as
/// `ACPPlanPillState.outlineIsAnimated(reduceMotion:)`.
enum ACPToolCallGroupHeaderAnimation {
    /// Whether a header whose member count just went from `previousCount` to
    /// `currentCount` should play the absorb pulse.
    ///
    /// Only growth means "a tool call just finished and folded in here". An
    /// unchanged count is an unrelated re-render, and a SHRINKING one is a
    /// regroup — history backfill re-keying a run, or a fork boundary
    /// splitting one — where nothing was absorbed and a flash would be a lie.
    static func absorbs(previousCount: Int, currentCount: Int, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        return currentCount > previousCount
    }
}
