import SwiftUI

struct ChatPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chat").font(.system(size: 18, weight: .semibold))
                Text("Defaults for ACP chat sessions, composer behavior, and chat typography.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Appearance") {
                    SettingsRow(name: "Font family") {
                        FontFamilyPicker(
                            family: state.bind(\.agents.chatFontFamily),
                            catalog: MonospaceFontCatalog.families()
                        )
                    }
                    SettingsRow(name: "Font size") {
                        AlasField(text: Binding(
                            get: { String(state.config.agents.chatFontSize) },
                            set: {
                                let raw = Int($0) ?? 13
                                state.config.agents.chatFontSize = max(8, min(64, raw))
                                state.saveConfig()
                            }
                        ), monospaced: true).frame(width: 80)
                    }
                }

                SettingsGroup(title: "Launcher (⌥⌘T)") {
                    SettingsRow(
                        name: "Default launch surface",
                        desc: "Whether the launcher opens on the Terminal or Chat tab. You can still swap with the segmented control inside the dialog."
                    ) {
                        defaultLauncherModePicker
                    }
                }

                SettingsGroup(title: "Composer") {
                    SettingsRow(name: "While busy, ⏎ queues; ⌥⏎ steers",
                                desc: "Turn off to swap — ⏎ steers and ⌥⏎ queues. Steering cancels the running turn and discards any pending queue items.") {
                        AlasToggle(on: Binding(
                            get: { state.config.harness.acpSendOnEnter },
                            set: {
                                state.config.harness.acpSendOnEnter = $0
                                state.saveConfig()
                            }
                        ))
                    }
                }

                SettingsGroup(title: "Sessions") {
                    SettingsRow(name: "Confirm before closing chat tabs",
                                desc: "Ask before closing Chat tabs with Command-W or the tab close button.") {
                        AlasToggle(on: Binding(
                            get: { state.config.harness.confirmCloseChatTabs },
                            set: {
                                state.config.harness.confirmCloseChatTabs = $0
                                state.saveConfig()
                            }
                        ))
                    }
                    SettingsRow(name: "⚡ Auto-run",
                                desc: "New chat sessions start with auto-run on — the agent runs tools without asking for permission. Toggle per-session with the bolt in the composer.") {
                        AlasToggle(on: Binding(
                            get: { state.config.harness.acpAutoRunByDefault },
                            set: {
                                state.config.harness.acpAutoRunByDefault = $0
                                state.saveConfig()
                            }
                        ))
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
    }

    private var defaultLauncherModePicker: some View {
        Picker("", selection: Binding(
            get: { state.config.agents.defaultLauncherMode },
            set: { newValue in
                state.config.agents.defaultLauncherMode = newValue
                state.saveConfig()
            }
        )) {
            Label("Terminal", systemImage: "terminal").tag(AppConfig.LauncherMode.terminal)
            Label("Chat", systemImage: "sparkle").tag(AppConfig.LauncherMode.acp)
        }
        .pickerStyle(.menu)
        .settingsDropdownFrame()
    }
}
