import SwiftUI

struct ChatPane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    enum GroupTitles {
        static let appearance = "Appearance"
        static let launcher = "Launcher (⌥⌘T)"
        static let composer = "Composer"
        static let sessions = "Sessions"
    }

    enum RowLabels {
        static let fontFamily = "Font family"
        static let fontSize = "Font size"
        static let defaultLaunchSurface = "Default launch surface"
        static let sendOnEnter = "While busy, ⏎ queues; ⌥⏎ steers"
        static let dictationLanguage = "Dictation language"
        static let confirmCloseChatTabs = "Confirm before closing chat tabs"
        static let autoRun = "⚡ Auto-run"
    }

    enum FontPickerDefaults {
        static let defaultLabel = "System"
        static let emptyCatalogMessage = "No fonts found"
    }

    static let groupTitles = [
        GroupTitles.appearance,
        GroupTitles.launcher,
        GroupTitles.composer,
        GroupTitles.sessions,
    ]

    static let rowLabels = [
        RowLabels.fontFamily,
        RowLabels.fontSize,
        RowLabels.defaultLaunchSurface,
        RowLabels.sendOnEnter,
        RowLabels.confirmCloseChatTabs,
        RowLabels.autoRun,
        RowLabels.dictationLanguage,
    ]

    /// Languages the dictation engine can transcribe. Loaded asynchronously
    /// because the Speech framework resolves them off-disk; stays empty
    /// below macOS 26, which also hides the row.
    @State private var dictationLocales: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Chat").font(.system(size: 18, weight: .semibold))
                Text("Defaults for ACP chat sessions, composer behavior, and chat typography.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: GroupTitles.appearance) {
                    SettingsRow(name: RowLabels.fontFamily) {
                        FontFamilyPicker(
                            family: state.bind(\.agents.chatFontFamily),
                            catalog: ChatFontCatalog.families(),
                            defaultLabel: FontPickerDefaults.defaultLabel,
                            emptyCatalogMessage: FontPickerDefaults.emptyCatalogMessage
                        )
                    }
                    SettingsRow(name: RowLabels.fontSize) {
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

                SettingsGroup(title: GroupTitles.launcher) {
                    SettingsRow(
                        name: RowLabels.defaultLaunchSurface,
                        desc: "Whether the launcher opens on the Terminal or Chat tab. You can still swap with the segmented control inside the dialog."
                    ) {
                        defaultLauncherModePicker
                    }
                }

                SettingsGroup(title: GroupTitles.composer) {
                    SettingsRow(name: RowLabels.sendOnEnter,
                                desc: "Turn off to swap — ⏎ steers and ⌥⏎ queues. Steering cancels the running turn and discards any pending queue items.") {
                        AlasToggle(on: Binding(
                            get: { state.config.harness.acpSendOnEnter },
                            set: {
                                state.config.harness.acpSendOnEnter = $0
                                state.saveConfig()
                            }
                        ))
                    }
                    if !dictationLocales.isEmpty {
                        SettingsRow(
                            name: RowLabels.dictationLanguage,
                            desc: "Language the 🎤 button transcribes. Automatic follows your app and system languages. Picking one that isn't downloaded yet fetches it the first time you dictate."
                        ) {
                            dictationLanguagePicker
                        }
                    }
                }

                SettingsGroup(title: GroupTitles.sessions) {
                    SettingsRow(name: RowLabels.confirmCloseChatTabs,
                                desc: "Ask before closing Chat tabs with Command-W or the tab close button.") {
                        AlasToggle(on: Binding(
                            get: { state.config.harness.confirmCloseChatTabs },
                            set: {
                                state.config.harness.confirmCloseChatTabs = $0
                                state.saveConfig()
                            }
                        ))
                    }
                    SettingsRow(name: RowLabels.autoRun,
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
        .task {
            dictationLocales = ACPDictationLocaleFormatter.sortedByDisplayName(
                await ACPSpeechDictationEngine.supportedLocaleIdentifiers()
            )
        }
    }

    private var dictationLanguagePicker: some View {
        Picker("", selection: Binding(
            get: { state.config.harness.acpDictationLocale },
            set: { newValue in
                state.config.harness.acpDictationLocale = newValue
                state.saveConfig()
            }
        )) {
            Text(ACPDictationLocaleFormatter.displayName(for: ACPDictationLocaleFormatter.automaticIdentifier))
                .tag(ACPDictationLocaleFormatter.automaticIdentifier)
            Divider()
            ForEach(dictationLocales, id: \.self) { identifier in
                Text(ACPDictationLocaleFormatter.displayName(for: identifier)).tag(identifier)
            }
        }
        .labelsHidden()
        .frame(width: 220)
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
