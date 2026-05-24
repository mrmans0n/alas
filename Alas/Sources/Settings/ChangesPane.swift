import SwiftUI

struct ChangesPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

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
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: state.bind(\.changes.prompt))
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 200, maxHeight: 320)
                                .scrollContentBackground(.hidden)
                                .background(theme.color("bg-2"))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(theme.color("line-soft"), lineWidth: 0.5)
                                )
                            HStack {
                                Spacer()
                                AlasButton(title: "Reset to default", style: .subtle) {
                                    state.config.changes.prompt = AppConfig.defaultCommitPrompt
                                    state.saveConfig()
                                }
                            }
                        }
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
                    AgentLogoView(agent: agent, size: 14)
                }
                .tag(agent.id)
            }
            Text("None").tag("none")
        }
        .pickerStyle(.menu)
        .frame(width: 240)
    }
}
