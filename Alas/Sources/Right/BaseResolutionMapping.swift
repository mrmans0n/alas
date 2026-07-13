import Foundation

extension GitService.BaseResolution {
    /// The resolution for the Commits section, given the global mode and
    /// whether this worktree has a manual per-worktree base override.
    static func forCommits(
        mode: AppConfig.Changes.ChangesComparisonMode,
        userOverrodeBaseBranch: Bool
    ) -> GitService.BaseResolution {
        if userOverrodeBaseBranch { return .baseLocalFirst }
        switch mode {
        case .auto: return .baseOriginFirst
        case .branchUpstream: return .upstreamThenBase
        case .manual: return .baseLocalFirst
        }
    }

    /// The resolution for the review-loop base. It never uses the branch's own
    /// upstream — it wants a stable remote base — so every non-Manual mode maps
    /// to origin-first.
    static func forReviewLoopBase(
        mode: AppConfig.Changes.ChangesComparisonMode,
        userOverrodeBaseBranch: Bool
    ) -> GitService.BaseResolution {
        if userOverrodeBaseBranch { return .baseLocalFirst }
        return mode == .manual ? .baseLocalFirst : .baseOriginFirst
    }
}
