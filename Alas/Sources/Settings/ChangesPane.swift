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
                    SettingsRow(name: "Tool",
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
            ForEach(menuItems, id: \.id) { item in
                Text(item.label).tag(item.id)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 240)
    }

    private struct MenuItem: Identifiable {
        let id: String
        let label: String
    }

    private var menuItems: [MenuItem] {
        var items: [MenuItem] = []
        // Show every enabled agent (installed or not). Disabled agents are
        // hidden — they're managed from Settings → Agents. Append
        // "(not installed)" to the label when the binary isn't detected.
        let installedIds = Set(state.agentRegistry.installed().map(\.id))
        for agent in state.agentRegistry.agents where agent.isEnabled {
            let suffix = installedIds.contains(agent.id) ? "" : " (not installed)"
            items.append(MenuItem(id: agent.id, label: agent.displayName + suffix))
        }
        items.append(MenuItem(id: "none", label: "None"))
        return items
    }
}
