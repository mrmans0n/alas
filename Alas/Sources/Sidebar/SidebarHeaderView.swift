import SwiftUI

struct SidebarHeaderView: View {
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onSearch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TrafficLights()
            Spacer()
            HStack(alignment: .center, spacing: 2) {
                ToolbarBtn(icon: "search", action: onSearch)
                ToolbarBtn(icon: "folder-plus", action: onAddProject)
                ToolbarBtn(icon: "gear", action: onSettings)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .windowDragHandle()
    }
}

struct ToolbarBtn: View {
    let icon: String
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
    }
}
