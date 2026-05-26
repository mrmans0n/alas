import SwiftUI

struct ChangesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Changes").font(.system(size: 18, weight: .semibold))
                Text("AI-generated commit messages and merge-conflict resolution.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Commit message") {
                    SettingsRow(name: "Agent",
                                desc: "Used by the sparkle button in the draft commit tab.") {
                        toolPicker
                    }
                    SettingsRow(name: "Prompt",
                                desc: "Instructions sent to the CLI. The staged diff is appended on stdin.") {
                        promptEditorRow(
                            windowId: "commit-prompt-editor",
                            currentValue: state.config.changes.prompt,
                            defaultValue: AppConfig.defaultCommitPrompt
                        )
                    }
                }

                SettingsGroup(title: "Merge conflicts") {
                    SettingsRow(name: "Bulk resolve prompt",
                                desc: "Sent to the agent CWD'd at the worktree when the user clicks 'Resolve all with agent'. The agent uses its own tools to enumerate, reconcile, and stage every conflicted file.") {
                        promptEditorRow(
                            windowId: "merge-bulk-prompt-editor",
                            currentValue: state.config.changes.mergeBulkResolvePrompt,
                            defaultValue: AppConfig.defaultMergeBulkResolvePrompt
                        )
                    }
                    SettingsRow(name: "Single-file prompt",
                                desc: "Used by 'Ask agent to resolve' in the merge editor toolbar. The three sides are appended automatically.") {
                        promptEditorRow(
                            windowId: "merge-single-prompt-editor",
                            currentValue: state.config.changes.mergeSingleResolvePrompt,
                            defaultValue: AppConfig.defaultMergeSingleResolvePrompt
                        )
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    /// Edit button + Custom chip, grouped together. Previously this row
    /// used a `Spacer()` between the two, which left them visually
    /// disconnected — flagged as "awful and unaligned" during dogfooding.
    private func promptEditorRow(
        windowId: String,
        currentValue: String,
        defaultValue: String
    ) -> some View {
        HStack(spacing: 8) {
            AlasButton(title: "Edit", style: .normal) {
                openWindow(id: windowId)
            }
            if currentValue != defaultValue {
                PromptStatusChip(label: "Custom")
            }
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
