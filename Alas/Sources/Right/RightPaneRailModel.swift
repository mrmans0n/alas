import Foundation

/// What a click on a rail tab button means, given what is currently active
/// and whether the pane body is collapsed.
enum RightPaneRailAction: Equatable {
    case collapse
    case expand(RightPaneTab)
    case select(RightPaneTab)

    static func resolve(tapped: RightPaneTab, active: RightPaneTab, collapsed: Bool) -> Self {
        if collapsed { return .expand(tapped) }
        return tapped == active ? .collapse : .select(tapped)
    }
}

/// The overlay a rail tab carries. `liveDot` signals activity without a
/// number; the Run tab uses it because the count is almost always one.
enum RightPaneRailBadge: Equatable {
    case none
    case count(Int)
    case liveDot

    /// Text drawn inside the badge pill, or `nil` when the badge draws no
    /// text. Capped so a large count cannot widen the 36pt rail.
    var displayText: String? {
        guard case .count(let value) = self else { return nil }
        return value > 99 ? "99+" : String(value)
    }
}

/// How a rail tab button paints. The collapsed active tab is its own state:
/// it drops its accent fill and becomes a muted "last used" marker.
enum RightPaneRailTabState: Equatable {
    case active
    case activeCollapsed
    case inactive
}

enum RightPaneRailModel {
    static func badge(
        for tab: RightPaneTab,
        changesCount: Int,
        activeAgentCount: Int,
        activeRunCount: Int
    ) -> RightPaneRailBadge {
        switch tab {
        case .changes: return changesCount > 0 ? .count(changesCount) : .none
        case .files:   return .none
        case .agent:   return activeAgentCount > 0 ? .count(activeAgentCount) : .none
        case .run:     return activeRunCount > 0 ? .liveDot : .none
        }
    }

    static func tabState(
        for tab: RightPaneTab,
        active: RightPaneTab,
        collapsed: Bool
    ) -> RightPaneRailTabState {
        guard tab == active else { return .inactive }
        return collapsed ? .activeCollapsed : .active
    }
}
