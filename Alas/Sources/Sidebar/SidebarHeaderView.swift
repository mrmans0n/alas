import SwiftUI

struct SidebarHeaderView: View {
    let onSearch: () -> Void
    let onSettings: () -> Void
    let onNewWorktree: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 12) {
            TrafficLights()
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .font(.system(size: 14))
                    .foregroundColor(theme.color("accent"))
                Text("Alas")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
            }
            Spacer()
            HStack(spacing: 2) {
                ToolbarBtn(icon: "search", action: onSearch)
                ToolbarBtn(icon: "gear", action: onSettings)
                ToolbarBtn(icon: "plus", action: onNewWorktree)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(
            Divider().opacity(0.5),
            alignment: .bottom
        )
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
                .background(hovering ? theme.color("bg-3") : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
