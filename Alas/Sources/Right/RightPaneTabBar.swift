import SwiftUI

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
        HStack(spacing: 8) {
            // Three segments no longer fit beside the summary and hide button
            // at the pane's 240pt minimum, so fall back to icon-only rather
            // than truncating every label to an ellipsis.
            ViewThatFits(in: .horizontal) {
                segments(compact: false)
                segments(compact: true)
            }

            Spacer(minLength: 8)
            trailing
            ToolbarBtn(icon: "sidebar.right", tooltip: "Hide changes pane", action: onHidePane)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .windowDragHandle()
    }

    private func segments(compact: Bool) -> some View {
        HStack(spacing: 2) {
            segment(.changes, icon: "diff", label: "Changes", count: changesCount, compact: compact)
            segment(.files, icon: "folder", label: "Files", count: nil, compact: compact)
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
                compact: compact
            )
            if RightPaneTab.available(runTabEnabled: showRunTab).contains(.run) {
                segment(
                    .run,
                    icon: "play",
                    label: "Run",
                    count: activeRunCount > 0 ? activeRunCount : nil,
                    compact: compact
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
        compact: Bool = false
    ) -> some View {
        let isOn = activeTab == tab
        return Button {
            activeTab = tab
        } label: {
            HStack(spacing: 5) {
                Icon(name: icon, size: 11, color: isOn ? theme.color("fg") : theme.color("fg-muted"))
                if !compact {
                    Text(label)
                        .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                        .foregroundColor(isOn ? theme.color("fg") : theme.color("fg-muted"))
                }
                if let count {
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
            .background(
                ZStack {
                    if isOn {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.color("bg-3"))
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: isOn ? Color.black.opacity(0.25) : .clear, radius: 1, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
