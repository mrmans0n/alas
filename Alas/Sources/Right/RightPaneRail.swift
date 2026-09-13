import SwiftUI

/// The right pane's vertical tab rail. Sits on the outer edge of the pane and
/// stays visible when the body collapses, so a collapsed pane can still be
/// reopened — and still shows live badges — without a separate reveal button.
struct RightPaneRail: View {
    static let width: CGFloat = 36

    let activeTab: RightPaneTab
    let collapsed: Bool
    let changesCount: Int
    var activeAgentCount: Int = 0
    var activeRunCount: Int = 0
    var showRunTab: Bool = false
    let onAction: (RightPaneRailAction) -> Void

    @Environment(\.theme) private var theme

    private var tabs: [RightPaneTab] {
        RightPaneTab.available(runTabEnabled: showRunTab)
    }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(tabs, id: \.rawValue) { tab in
                RightPaneRailButton(
                    tab: tab,
                    label: Self.label(for: tab),
                    icon: Self.icon(for: tab),
                    state: RightPaneRailModel.tabState(for: tab, active: activeTab, collapsed: collapsed),
                    badge: RightPaneRailModel.badge(
                        for: tab,
                        changesCount: changesCount,
                        activeAgentCount: activeAgentCount,
                        activeRunCount: activeRunCount
                    ),
                    collapsed: collapsed,
                    onTap: {
                        onAction(RightPaneRailAction.resolve(tapped: tab, active: activeTab, collapsed: collapsed))
                    }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 3)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // No opaque fill of its own: the rail sits over the same
        // `SidebarMaterialBackground` as the rest of the expanded pane, and
        // an opaque background here would occlude it just for this column.
        .overlay(Divider().opacity(0.5), alignment: .leading)
    }

    static func label(for tab: RightPaneTab) -> String {
        switch tab {
        case .changes: return "Changes"
        case .files:   return "Files"
        case .agent:   return "Agent"
        case .run:     return "Run"
        }
    }

    static func icon(for tab: RightPaneTab) -> String {
        switch tab {
        case .changes: return "diff"
        case .files:   return "folder"
        case .agent:   return "person.crop.circle"
        case .run:     return "play"
        }
    }
}

private struct RightPaneRailButton: View {
    let tab: RightPaneTab
    let label: String
    let icon: String
    let state: RightPaneRailTabState
    let badge: RightPaneRailBadge
    let collapsed: Bool
    let onTap: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Icon(name: icon, size: 14, color: foreground)
                .frame(width: 26, height: 26)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
        case .inactive:        return hovering ? theme.color("fg-muted") : theme.color("fg-faint")
        }
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .active:
            RoundedRectangle(cornerRadius: 6).fill(theme.color("accent-soft"))
        case .activeCollapsed:
            RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5)
        case .inactive:
            if hovering {
                // A theme token rather than a white wash: the rail sits on
                // `bg-1`, and `bg-3` reads as a subtle step away from it in
                // both the dark and the light theme.
                RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-3"))
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
            RoundedRectangle(cornerRadius: 1)
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
                .fill(theme.color("add"))
                .frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(theme.color("bg-1"), lineWidth: 1.5))
                .offset(x: 2, y: -2)
        case .count:
            if let text = badge.displayText {
                Text(text)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(theme.color("fg-muted"))
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 12)
                    .background(Capsule().fill(theme.color("bg-4")))
                    .overlay(Capsule().strokeBorder(theme.color("bg-1"), lineWidth: 1.5))
                    .offset(x: 4, y: -3)
            }
        }
    }

    private var accessibilityLabel: String {
        // The live dot draws no text, so VoiceOver would otherwise hear
        // nothing at all where a sighted user sees activity.
        if badge == .liveDot { return "\(label), running" }
        guard let text = badge.displayText else { return label }
        return "\(label), \(text)"
    }
}
