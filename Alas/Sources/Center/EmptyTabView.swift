import SwiftUI

struct EmptyTabView: View {
    let onNewTerminal: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                Image(systemName: "airplane")
                    .font(.system(size: 30))
                    .foregroundColor(theme.color("accent"))
            }
            Text("No tabs open")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Open a terminal to start working in this worktree.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
            AlasButton(title: "New terminal", icon: "terminal", style: .primary, action: onNewTerminal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
