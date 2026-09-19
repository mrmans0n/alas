import Foundation

/// Shared widths for the two side rails of the review surface.
enum DiffReviewRailMetrics {
    static let expandedWidth: CGFloat = 260
    static let collapsedWidth: CGFloat = 44
}

/// Where the draft review summary (comments plus their actions) lives for a
/// given review-surface width.
///
/// The summary normally sits in a fixed-width rail on the trailing edge. When
/// the surface is too narrow for that rail to leave a usable diff in the
/// center, the rail is dropped and the same content is appended after the
/// diff stack instead, the way GitHub and GitLab lay out a review.
enum DiffReviewSummaryPlacement: Equatable {
    case rail
    case inline

    /// Narrowest center the surface keeps the summary rail for. Below this the
    /// diff would be squeezed into a strip too narrow to read, so the rail
    /// yields its width to the center.
    static let minimumCenterWidthForRail: CGFloat = 520

    static func resolve(
        availableWidth: CGFloat,
        fileRailCollapsed: Bool,
        summaryRailCollapsed: Bool = false
    ) -> DiffReviewSummaryPlacement {
        guard availableWidth.isFinite, availableWidth > 0 else { return .rail }
        let fileRailWidth = fileRailCollapsed
            ? DiffReviewRailMetrics.collapsedWidth
            : DiffReviewRailMetrics.expandedWidth
        let summaryRailWidth = summaryRailCollapsed
            ? DiffReviewRailMetrics.collapsedWidth
            : DiffReviewRailMetrics.expandedWidth
        let centerWidthWithRail = availableWidth - fileRailWidth - summaryRailWidth
        return centerWidthWithRail >= minimumCenterWidthForRail ? .rail : .inline
    }
}
