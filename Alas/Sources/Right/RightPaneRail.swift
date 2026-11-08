import SwiftUI

/// The right pane's vertical tab rail. Sits on the outer edge of the pane and
/// stays visible when the body collapses, so a collapsed pane can still be
/// reopened — and still shows live badges — without a separate reveal button.
struct RightPaneRail: View {
    static let width: CGFloat = 36

    /// Nil while a plugin panel is selected.
    let activeTab: RightPaneTab?
    let collapsed: Bool
    let changesCount: Int
    var activeAgentCount: Int = 0
    var activeRunCount: Int = 0
    var activeScheduleCount: Int = 0
    var tabs: [RightPaneTab] = RightPaneTab.available()
    var panels: [PluginPanelItem] = []
    var activePanel: PluginPanelRef?
    var onPanel: (PluginPanelRef) -> Void = { _ in }
    let onAction: (RightPaneRailAction) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(spacing: 3) {
            ForEach(tabs, id: \.rawValue) { tab in
                RightPaneRailButton(
                    label: Self.label(for: tab),
                    icon: Self.icon(for: tab),
                    state: RightPaneRailModel.tabState(for: tab, active: activeTab, collapsed: collapsed),
                    badge: RightPaneRailModel.badge(
                        for: tab,
                        changesCount: changesCount,
                        activeAgentCount: activeAgentCount,
                        activeRunCount: activeRunCount,
                        activeScheduleCount: activeScheduleCount
                    ),
                    collapsed: collapsed,
                    onTap: {
                        onAction(RightPaneRailAction.resolve(tapped: tab, active: activeTab, collapsed: collapsed))
                    }
                )
            }
            // Plugins can add any number of panels, so their part of the rail scrolls rather than overflowing.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(panels) { panel in
                        let badge = RightPaneRailModel.badge(for: panel.badge)
                        RightPaneRailButton(
                            label: panel.title,
                            icon: panel.icon,
                            state: panel.ref != activePanel ? .inactive : collapsed ? .activeCollapsed : .active,
                            badge: badge.badge,
                            tone: badge.tone,
                            dotLabel: "needs attention",
                            collapsed: collapsed,
                            onTap: { onPanel(panel.ref) }
                        )
                    }
                }
                .padding(.horizontal, scale.space[1])
            }
            .frame(width: Self.width)
            .scrollBounceBehavior(.basedOnSize)
            Spacer(minLength: 0)
        }
        .padding(.vertical, scale.space[1])
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Neither a fill nor a divider: the rail sits over the same
        // `SidebarMaterialBackground` as the rest of the pane, and the pane's
        // bands float inset from this edge (see `PaneBandLayout`), so there is
        // no content running up to the rail that needs a boundary drawn.
    }

    static func label(for tab: RightPaneTab) -> String {
        switch tab {
        case .changes: return "Changes"
        case .files:   return "Files"
        case .agent:   return "Agent"
        case .run:     return "Run"
        case .schedules: return "Schedules"
        case .device:  return "Devices"
        }
    }

    static func icon(for tab: RightPaneTab) -> String {
        switch tab {
        case .changes: return "diff"
        case .files:   return "folder"
        case .agent:   return "cpu"
        case .run:     return "play"
        case .schedules: return "clock"
        case .device:  return "iphone"
        }
    }
}

private struct RightPaneRailButton: View {
    let label: String
    let icon: String
    let state: RightPaneRailTabState
    let badge: RightPaneRailBadge
    /// The theme color a badge fills with; nil keeps the built-in look.
    var tone: String? = nil
    /// What VoiceOver says for a dot.
    var dotLabel = "running"
    let collapsed: Bool
    let onTap: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Icon(name: icon, size: 16, color: foreground)
                .frame(width: 28, height: 28)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
                .overlay(alignment: .leading) { collapsedMarker }
                .overlay(alignment: .topTrailing) { badgeView }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? "Open \(label)" : label)
        .accessibilityLabel(accessibilityLabel)
        // `.activeCollapsed` is still the selected tab — it is the one the
        // pane reopens on — so it carries the trait too.
        .accessibilityAddTraits(state == .active || state == .activeCollapsed ? .isSelected : [])
    }

    private var foreground: Color {
        switch state {
        case .active:          return theme.color("accent")
        case .activeCollapsed: return theme.color("fg-dim")
        case .inactive:        return hovering ? theme.color("fg") : theme.color("fg-muted")
        }
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .active:
            RoundedRectangle(cornerRadius: scale.radius.medium).fill(theme.color("accent-soft"))
        case .activeCollapsed:
            RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5)
        case .inactive:
            if hovering {
                // A theme token rather than a white wash: the rail sits on
                // `bg-1`, and `bg-3` reads as a subtle step away from it in
                // both the dark and the light theme.
                RoundedRectangle(cornerRadius: scale.radius.medium).fill(theme.color("bg-3"))
            } else {
                Color.clear
            }
        }
    }

    /// The collapsed active tab keeps a leading edge marker so the rail still
    /// records which tab the pane will reopen on. Accent-colored like the
    /// expanded selection fill, so it still reads as "selected", not just
    /// "last used."
    @ViewBuilder
    private var collapsedMarker: some View {
        if state == .activeCollapsed {
            RoundedRectangle(cornerRadius: scale.space[0] / 2)
                .fill(theme.color("accent"))
                .frame(width: 2, height: 12)
                .offset(x: -3)
        }
    }

    @ViewBuilder
    private var badgeView: some View {
        switch badge {
        case .none:
            EmptyView()
        case .liveDot:
            Circle()
                .fill(theme.color(tone ?? "add"))
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(theme.color("bg-1"), lineWidth: 1.5))
                .padding(scale.space[0])
        case .count:
            if let text = badge.displayText {
                Text(text)
                    .font(scale.caption.font(weight: .bold))
                    .foregroundColor(theme.color(tone == nil ? "fg-muted" : "bg-1"))
                    .padding(.horizontal, scale.space[0])
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(theme.color(tone ?? "bg-4")))
                    .overlay(Capsule().strokeBorder(theme.color("bg-1"), lineWidth: 1.5))
            }
        }
    }

    private var accessibilityLabel: String {
        // The live dot draws no text, so VoiceOver would otherwise hear
        // nothing at all where a sighted user sees activity.
        if badge == .liveDot { return "\(label), \(dotLabel)" }
        guard let text = badge.displayText else { return label }
        return "\(label), \(text)"
    }
}
