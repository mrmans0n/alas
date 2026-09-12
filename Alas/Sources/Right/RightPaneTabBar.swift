import SwiftUI

enum RightPaneTabBarLayout {
    case regular
    case compact
    case iconOnly

    func showsLabel(for tab: RightPaneTab, activeTab: RightPaneTab) -> Bool {
        self == .regular || (self == .compact && tab == activeTab)
    }

    func showsCount(for tab: RightPaneTab, activeTab: RightPaneTab) -> Bool {
        self == .regular || (self == .compact && tab == activeTab)
    }

    func accessibilityLabel(_ label: String, count: Int?, for tab: RightPaneTab, activeTab: RightPaneTab) -> String {
        guard let count, showsCount(for: tab, activeTab: activeTab) else {
            return label
        }
        return "\(label), \(count)"
    }
}

struct RightPaneTabBar: View {
    @Binding var activeTab: RightPaneTab
    let changesCount: Int
    let totalAdd: Int
    let totalDel: Int
    let onHidePane: () -> Void
    let showIgnored: Bool
    let onToggleShowIgnored: () -> Void
    var showRunTab: Bool = false
    /// Number of commands currently starting or running in this worktree.
    var activeRunCount: Int = 0
    /// Number of non-detached Agent sidebar rows in this worktree.
    var activeAgentCount: Int = 0

    @Environment(\.theme) private var theme

    var body: some View {
        header
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .windowDragHandle()
    }

    private var header: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                segments(layout: .regular)
                segments(layout: .compact)
                segments(layout: .iconOnly)
            }

            Spacer(minLength: 8)
            trailing
            ToolbarBtn(icon: "sidebar.right", tooltip: "Hide changes pane", action: onHidePane)
        }
    }

    private func segments(layout: RightPaneTabBarLayout) -> some View {
        HStack(spacing: 2) {
            segment(.changes, icon: "diff", label: "Changes", count: changesCount, layout: layout)
            segment(.files, icon: "folder", label: "Files", count: nil, layout: layout)
                .contextMenu {
                    Toggle("Show ignored or excluded files", isOn: Binding(
                        get: { showIgnored },
                        set: { _ in onToggleShowIgnored() }
                    ))
                }
            segment(
                .agent,
                icon: "person.crop.circle",
                label: "Agent",
                count: activeAgentCount > 0 ? activeAgentCount : nil,
                layout: layout
            )
            if RightPaneTab.available(runTabEnabled: showRunTab).contains(.run) {
                segment(
                    .run,
                    icon: "play",
                    label: "Run",
                    count: activeRunCount > 0 ? activeRunCount : nil,
                    layout: layout
                )
            }
        }
        .padding(2)
        .background(theme.color("seg-container-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func segment(
        _ tab: RightPaneTab,
        icon: String,
        label: String,
        count: Int?,
        layout: RightPaneTabBarLayout
    ) -> some View {
        RightPaneSegmentButton(
            activeTab: $activeTab,
            tab: tab,
            icon: icon,
            label: label,
            count: count,
            layout: layout
        )
    }

    @ViewBuilder
    private var trailing: some View {
        switch activeTab {
        case .changes:
            if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                HStack(spacing: 6) {
                    Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                    Text("−\(totalDel)").foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.trailing, 4)
            }
        case .files, .agent, .run:
            EmptyView()
        }
    }
}

private struct RightPaneSegmentButton: View {
    @Binding var activeTab: RightPaneTab
    let tab: RightPaneTab
    let icon: String
    let label: String
    let count: Int?
    let layout: RightPaneTabBarLayout

    @Environment(\.theme) private var theme

    private var isOn: Bool { activeTab == tab }

    var body: some View {
        Button {
            activeTab = tab
        } label: {
            HStack(spacing: 5) {
                Icon(name: icon, size: 11, color: isOn ? theme.color("fg") : theme.color("fg-muted"))
                if layout.showsLabel(for: tab, activeTab: activeTab) {
                    Text(label)
                        .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                        .foregroundColor(isOn ? theme.color("fg") : theme.color("fg-muted"))
                }
                if let count, layout.showsCount(for: tab, activeTab: activeTab) {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(minWidth: 16, minHeight: 14)
                        .padding(.horizontal, 4)
                        .background(isOn ? theme.color("seg-pill-active-bg") : theme.color("seg-pill-bg"))
                        .foregroundColor(isOn ? theme.color("seg-pill-active-fg") : theme.color("fg-muted"))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(selectionBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: isOn ? Color.black.opacity(0.25) : .clear, radius: 1, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.accessibilityLabel(label, count: count, for: tab, activeTab: activeTab))
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(label)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isOn {
            RoundedRectangle(cornerRadius: 4)
                .fill(theme.color("bg-3"))
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                .blendMode(.plusLighter)
        }
    }
}
