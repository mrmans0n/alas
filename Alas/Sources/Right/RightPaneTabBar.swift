import SwiftUI

struct RightPaneTabBar: View {
    @Binding var activeTab: RightPaneTab
    let changesCount: Int
    let totalAdd: Int
    let totalDel: Int
    let onHidePane: () -> Void
    let showIgnored: Bool
    let onToggleShowIgnored: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            segment(.changes, icon: "diff", label: "Changes", count: changesCount)
            segment(.files,   icon: "folder", label: "Files",  count: nil)
                .contextMenu {
                    Toggle("Show ignored or excluded files", isOn: Binding(
                        get: { showIgnored },
                        set: { _ in onToggleShowIgnored() }
                    ))
                }
            Spacer(minLength: 8)
            trailing
            ToolbarBtn(icon: "sidebar.right", action: onHidePane)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .windowDragHandle()
    }

    private func segment(_ tab: RightPaneTab, icon: String, label: String, count: Int?) -> some View {
        let isOn = activeTab == tab
        return Button {
            activeTab = tab
        } label: {
            HStack(spacing: 5) {
                Icon(name: icon, size: 11, color: isOn ? theme.color("fg") : theme.color("fg-muted"))
                Text(label)
                    .font(.system(size: 11.5, weight: isOn ? .semibold : .medium))
                    .foregroundColor(isOn ? theme.color("fg") : theme.color("fg-muted"))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(isOn ? theme.color("accent-soft") : theme.color("bg-4"))
                        .foregroundColor(isOn ? theme.color("accent") : theme.color("fg-muted"))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isOn ? theme.color("bg-3") : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        case .files:
            EmptyView()
        }
    }
}
