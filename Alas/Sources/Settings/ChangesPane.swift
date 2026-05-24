import SwiftUI

struct ChangesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Changes").font(.system(size: 18, weight: .semibold))
                Text("AI-generated commit messages and related defaults.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Commit message") {
                    SettingsRow(name: "Agent",
                                desc: "Used by the sparkle button in the commit composer.") {
                        toolPicker
                    }
                    SettingsRow(name: "Prompt",
                                desc: "Instructions sent to the CLI. The staged diff is appended on stdin.") {
                        HStack(spacing: 12) {
                            AlasButton(title: "Edit", style: .normal) {
                                openWindow(id: "commit-prompt-editor")
                            }
                            Spacer()
                            if let chipLabel = CommitPromptStatus.chipLabel(for: state.config.changes.prompt) {
                                PromptStatusChip(label: chipLabel)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private var toolPicker: some View {
        Picker("", selection: state.bind(\.changes.aiToolId)) {
            // `agent.isEnabled` is clamped against install detection in
            // AgentRegistry, so every entry here is both enabled and installed.
            ForEach(state.agentRegistry.agents.filter(\.isEnabled)) { agent in
                Label {
                    Text(agent.displayName)
                } icon: {
                    Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
                }
                .tag(agent.id)
            }
            Text("None").tag("none")
        }
        .pickerStyle(.menu)
        .frame(width: 240)
    }
}

private struct PromptStatusChip: View {
    let label: String
    @Environment(\.theme) var theme

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(theme.color("fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.color("line-soft"), lineWidth: 0.5)
            )
    }
}
