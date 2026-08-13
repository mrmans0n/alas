import SwiftUI

struct EmptyTabView: View {
    static let emptyIcon = "🥺"

    let onNewTerminal: () -> Void
    let onNewAgentInChat: () -> Void
    let onNewAgentInTerminal: () -> Void
    let newTerminalShortcut: String?
    let newAgentInChatShortcut: String?
    let newAgentInTerminalShortcut: String?
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color("line"), lineWidth: 0.5))
                Text(Self.emptyIcon)
                    .font(.system(size: 34))
                    .shadow(color: theme.color("accent").opacity(0.2), radius: 8, y: 3)
                    .accessibilityLabel("No tabs icon")
            }
            VStack(spacing: 5) {
                Text("No tabs open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text("Choose how to start working in this worktree.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }
            VStack(spacing: 8) {
                EmptyTabActionRow(
                    icon: "terminal",
                    title: "New Terminal",
                    subtitle: "Open a shell in this worktree",
                    shortcut: newTerminalShortcut,
                    action: onNewTerminal
                )
                EmptyTabActionRow(
                    icon: "sparkle",
                    title: "New Agent in Chat",
                    subtitle: "Pick an ACP-capable agent for chat",
                    shortcut: newAgentInChatShortcut,
                    action: onNewAgentInChat
                )
                EmptyTabActionRow(
                    icon: "sparkle",
                    title: "New Agent in Terminal",
                    subtitle: "Pick an agent to run in a terminal",
                    shortcut: newAgentInTerminalShortcut,
                    action: onNewAgentInTerminal
                )
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}

private struct EmptyTabActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let shortcut: String?
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Icon(name: icon, size: 14,
                     color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                        .padding(.horizontal, 6)
                        .frame(height: 21)
                        .background(theme.color("bg-2"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(theme.color("line"), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background(hovering ? theme.color("bg-3") : theme.color("bg-2").opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
