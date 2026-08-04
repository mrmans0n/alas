import SwiftUI

struct SidebarHeaderView: View {
    let worktreeSortMode: AppConfig.WorktreeSortMode
    let onSetWorktreeSortMode: (AppConfig.WorktreeSortMode) -> Void
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onSearch: () -> Void
    let onHideSidebar: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TrafficLights()
            Spacer()
            HStack(alignment: .center, spacing: 2) {
                WorktreeSortMenu(
                    selection: worktreeSortMode,
                    onSelect: onSetWorktreeSortMode,
                    headerHovered: hovering
                )
                ToolbarBtn(icon: "search", tooltip: "Search", action: onSearch)
                ToolbarBtn(icon: "folder-plus", tooltip: "Add repository", action: onAddProject)
                ToolbarBtn(icon: "gear", tooltip: "Settings", action: onSettings)
                ToolbarBtn(icon: "sidebar.left", tooltip: "Hide sidebar", action: onHideSidebar)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .windowDragHandle()
    }
}

struct ToolbarBtn: View {
    let icon: String
    let tooltip: String
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: 13, color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
                .background(hovering ? theme.color("bg-3") : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }
}
