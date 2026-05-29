import Foundation

/// Pure decision function for whether the inline plan sidebar should
/// be shown. Hysteresis (820/900 dead band) prevents flicker when the
/// user drags a pane divider near the boundary, or when the right pane
/// animates open/closed.
///
/// Spec: `docs/superpowers/specs/2026-05-29-acp-plan-sidebar-design.md`
enum ACPPlanSidebarVisibility {
    /// Width at or above which a hidden sidebar appears.
    static let showThreshold: CGFloat = 900

    /// Width strictly below which a shown sidebar hides.
    static let hideThreshold: CGFloat = 820

    /// Returns the next visibility given the current pane width, whether
    /// a plan is available, and whether the sidebar is currently shown.
    ///
    /// - If no plan: always hidden (the sidebar has no empty state).
    /// - If width ≥ `showThreshold`: shown.
    /// - If width < `hideThreshold`: hidden.
    /// - Otherwise (dead band): keep `current`.
    static func next(paneWidth: CGFloat, hasPlan: Bool, current: Bool) -> Bool {
        guard hasPlan else { return false }
        if paneWidth >= showThreshold { return true }
        if paneWidth < hideThreshold { return false }
        return current
    }
}
