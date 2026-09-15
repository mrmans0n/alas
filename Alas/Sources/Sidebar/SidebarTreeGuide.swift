import CoreGraphics

/// Geometry for the sidebar's worktree tree guide: the vertical rail that
/// nests worktrees under their repo, the short elbow tick joining each row to
/// it, and the dot marking the selected row on the rail.
///
/// `RepoGroupView` draws the rail; `WorktreeRowView` draws the elbow and the
/// dot. They line up only because both read these constants, so they live
/// here rather than inline at either site.
///
/// Values come from `Sidebar E1.html` (`.kids`, `.wt:before`, `.wt.sel:after`).
enum SidebarTreeGuide {
    /// Leading inset applied twice by the rail container: once as the outer
    /// margin before the rail, once as the inner padding after it.
    static let indent: CGFloat = 13
    static let railWidth: CGFloat = 1

    /// The horizontal tick joining a row to the rail.
    static let elbowWidth: CGFloat = 8
    static let elbowHeight: CGFloat = 1
    /// Distance from the row's top edge down to the elbow, placing it on the
    /// vertical centre of the row's first line.
    static let elbowOffsetY: CGFloat = 16

    static let selectionDotDiameter: CGFloat = 5
    static let selectionDotOffsetY: CGFloat = 13

    /// Leading offset for the elbow, relative to the row's leading edge.
    /// Negative — the elbow lives in the container's padding, left of the row.
    static var elbowOffsetX: CGFloat { -indent }

    /// Leading offset for the selection dot, relative to the row's leading
    /// edge, centring the dot on the rail.
    ///
    /// E1 hardcodes -16, which lands the dot 1px left of the rail's centre.
    /// Computing the centre instead reads as deliberate rather than as an
    /// off-by-one, at the cost of a 1px deviation from the mock.
    static var selectionDotOffsetX: CGFloat {
        -indent - (selectionDotDiameter - railWidth) / 2
    }
}
