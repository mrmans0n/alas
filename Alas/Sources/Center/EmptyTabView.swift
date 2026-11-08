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
    @Environment(\.designScale) private var scale
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
        VStack(spacing: scale.space[4]) {
            LovebirdView(pose: .idle)
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            VStack(spacing: scale.space[1]) {
                Text("No tabs open")
                    .font(.system(size: 15, weight: .semibold)) // design-literal: hero title
                    .foregroundColor(theme.color("fg"))
                Text(subtitle)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
            }
            if !actions.isEmpty {
                VStack(spacing: scale.space[2]) {
                    ForEach(actions) { EmptyTabActionRow(item: $0) }
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(scale.space[5])
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .padding(.horizontal, scale.space[5])
    }
}

private struct EmptyTabActionRow: View {
    @Environment(\.designScale) private var scale
    let item: EmptyTabAction
    @Environment(\.theme) var theme
    @State private var hovering = false

    var body: some View {
        Button(action: item.action) {
            HStack(spacing: scale.space[2]) {
                Icon(name: item.icon, size: 14,
                     color: hovering ? theme.color("fg") : theme.color("fg-muted"))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: scale.space[0]) {
                    Text(item.title)
                        .font(scale.emphasisFont)
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.subtitle)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(scale.meta.font(weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                        .padding(.horizontal, scale.space[2])
                        .frame(height: 21)
                        .background(theme.color("bg-2"))
                        .overlay(
                            RoundedRectangle(cornerRadius: scale.radius.small)
                                .strokeBorder(theme.color("line"), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, scale.space[3])
            .frame(height: 48)
            .background(hovering ? theme.color("bg-3") : theme.color("bg-2").opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
