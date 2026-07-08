import Foundation

/// Keeps the review stream deterministic: every loaded file is render-eligible,
/// and SwiftUI's `LazyVStack` is the only virtualization layer.
enum DiffReviewRenderEligibility {
    static func fileIDs(ordered: [DiffReviewFileID]) -> Set<DiffReviewFileID> {
        Set(ordered)
    }
}
