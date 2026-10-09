import SwiftUI

struct EmptyTabAction: Identifiable {
    let icon: String
    let title: String
    let subtitle: String
    var shortcut: String?
    let action: () -> Void
    var id: String { title }
}

struct EmptyTabView: View {
    var subtitle = "Choose how to start working in this worktree."
    let actions: [EmptyTabAction]
    @Environment(\.theme) var theme

    init(subtitle: String, actions: [EmptyTabAction]) {
        self.subtitle = subtitle
        self.actions = actions
    }

    init(
        onNewTerminal: @escaping () -> Void,
        onNewAgentInChat: @escaping () -> Void,
        onNewAgentInTerminal: @escaping () -> Void,
        newTerminalShortcut: String?,
        newAgentInChatShortcut: String?,
        newAgentInTerminalShortcut: String?
    ) {
        actions = [
            EmptyTabAction(icon: "terminal", title: "New Terminal", subtitle: "Open a shell in this worktree",
                           shortcut: newTerminalShortcut, action: onNewTerminal),
            EmptyTabAction(icon: "sparkle", title: "New Agent in Chat", subtitle: "Pick an ACP-capable agent for chat",
                           shortcut: newAgentInChatShortcut, action: onNewAgentInChat),
            EmptyTabAction(icon: "sparkle", title: "New Agent in Terminal", subtitle: "Pick an agent to run in a terminal",
                           shortcut: newAgentInTerminalShortcut, action: onNewAgentInTerminal),
        ]
    }

    var body: some View {
        ForestScene(mode: .idle) {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            Image(systemName: "bird.fill")
                .font(.system(size: 30))
                .foregroundStyle(theme.color("accent").gradient)
                .shadow(color: theme.color("accent").opacity(0.3), radius: 8, y: 3)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("No tabs open")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
            }
            if !actions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(actions) { EmptyTabActionRow(item: $0) }
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .padding(.horizontal, 24)
    }
}

private struct EmptyTabActionRow: View {
    let item: EmptyTabAction
    @Environment(\.theme) var theme
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: 10) {
                Icon(name: item.icon, size: 14,
                     color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                if let shortcut = item.shortcut {
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
