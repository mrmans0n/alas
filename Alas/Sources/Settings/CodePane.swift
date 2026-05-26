import SwiftUI

struct CodePane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    @State private var selected: LanguageServerConfig?
    @State private var creatingNew = false
    @State private var installSheetVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Code").font(.system(size: 18, weight: .semibold))
                Text("Syntax highlighting and language servers for editor panes.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Appearance") {
                    SettingsRow(name: "Font family") {
                        FontFamilyPicker(
                            family: state.bind(\.code.fontFamily),
                            catalog: MonospaceFontCatalog.families()
                        )
                    }
                    SettingsRow(name: "Font size") {
                        AlasField(text: Binding(
                            get: { String(state.config.code.fontSize) },
                            set: {
                                let raw = Int($0) ?? 13
                                state.config.code.fontSize = max(8, min(64, raw))
                                state.saveConfig()
                            }
                        ), monospaced: true).frame(width: 80)
                    }
                    SettingsRow(name: "Format on save",
                                desc: "Request document formatting from the language server before writing to disk.") {
                        AlasToggle(on: state.bind(\.code.formatOnSave))
                    }
                }

                SettingsGroup(title: "Languages") {
                    ForEach(allEntries(), id: \.id) { entry in
                        SettingsRow(name: entry.language,
                                    desc: entry.extensions.joined(separator: ", ")) {
                            HStack(spacing: 8) {
                                statusBadge(for: entry)
                                installAffordance(for: entry)
                                AlasButton(title: "Edit",
                                           style: .subtle,
                                           action: { selected = entry })
                            }
                        }
                    }
                    SettingsRow(name: "Add language",
                                desc: "Register a custom language server.") {
                        AlasButton(title: "Add", action: { creatingNew = true })
                    }
                    if !state.config.code.dismissedInstallNudges.isEmpty {
                        SettingsRow(name: "Reset dismissed nudges",
                                    desc: "Re-show editor install prompts for languages you dismissed.") {
                            AlasButton(title: "Reset", style: .subtle, action: {
                                state.config.code.dismissedInstallNudges = []
                                state.saveConfig()
                            })
                        }
                    }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .sheet(item: $selected) { entry in
            CodeLanguageDetailView(
                initial: entry,
                isNew: false,
                onSave: { saved, _ in save(originalLanguage: entry.language, saved, recipes: nil) },
                onCancel: { selected = nil }
            )
        }
        .sheet(isPresented: $creatingNew) {
            CodeLanguageDetailView(
                initial: blank(),
                isNew: true,
                onSave: { saved, recipes in save(originalLanguage: nil, saved, recipes: recipes) },
                onCancel: { creatingNew = false }
            )
        }
        .sheet(isPresented: $installSheetVisible, onDismiss: {
            // Interactive dismiss (Escape, click-out) bypasses the sheet's
            // own buttons; reset the installer so the next install starts clean.
            state.lspInstaller.reset()
        }) {
            LSPInstallProgressSheet(installer: state.lspInstaller) { completedLanguage in
                installSheetVisible = false
                state.refreshInstallerHost()
                // Re-fire didOpen for any open buffers in the just-installed
                // language so their hover/diagnostics/definitions wake up
                // without the user closing and reopening the tab.
                if let completedLanguage {
                    state.tabs.reopenLSPDocuments(forLanguage: completedLanguage)
                }
            }
        }
    }

    private func allEntries() -> [LanguageServerConfig] {
        let registry = LanguageServerRegistry(userDefined: state.config.code.languageServers)
        return registry.allEntries()
    }

    private let availability = LanguageServerAvailability()

    private func statusBadge(for entry: LanguageServerConfig) -> some View {
        let label: String
        let color: Color
        switch availability.status(for: entry) {
        case .disabled:
            label = "Disabled"
            color = theme.color("fg-faint")
        case .available:
            label = "Available"
            color = theme.color("add")
        case .notInstalled:
            label = "Not installed"
            color = theme.color("warn")
        case .blockedByGatekeeper:
            label = "Blocked by Gatekeeper"
            color = theme.color("warn")
        }
        return Text(label).font(.system(size: 10.5)).foregroundColor(color)
    }

    @ViewBuilder
    private func installAffordance(for entry: LanguageServerConfig) -> some View {
        let recipes = recipes(for: entry.language)
        let status = availability.status(for: entry)
        if status == .notInstalled, !recipes.isEmpty {
            InstallSplitButton(
                recipes: recipes,
                available: state.installerHost.allAvailable(in: recipes),
                busy: installBusy,
                onInstall: { installer, recipe in
                    runInstall(installer, recipe: recipe, language: entry.language)
                }
            )
        }
    }

    private var installBusy: Bool {
        if case .running = state.lspInstaller.state { return true } else { return false }
    }

    private func recipes(for language: String) -> [InstallRecipe] {
        // userDefinedRecipes wins when present — a user who Mason-prefilled
        // a Ruff config under the `python` language ID needs the Install
        // button to run Ruff's recipe, not the curated Pyright one.
        if let user = state.config.code.userDefinedRecipes[language], !user.isEmpty {
            return user
        }
        if let curated = RecommendedLanguageCatalog.entry(forLanguage: language) {
            return curated.resolvedRecipes
        }
        return []
    }

    private func runInstall(_ installer: DetectedInstaller, recipe: InstallRecipe, language: String) {
        installSheetVisible = true
        Task {
            try? await state.lspInstaller.install(recipe: recipe, using: installer, language: language)
        }
    }

    private func save(originalLanguage: String?, _ entry: LanguageServerConfig, recipes: [InstallRecipe]?) {
        state.config.code.saveLanguageServerConfig(originalLanguage: originalLanguage, entry, recipes: recipes)
        state.saveConfig()
        selected = nil
        creatingNew = false
    }

    private func blank() -> LanguageServerConfig {
        LanguageServerConfig(
            language: "",
            extensions: [],
            command: "",
            args: [],
            env: [:],
            rootMarkers: [".git"],
            enabled: true
        )
    }
}
