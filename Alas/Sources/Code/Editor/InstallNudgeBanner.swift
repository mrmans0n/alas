import SwiftUI

/// A non-blocking banner shown above the editor when the file's language has
/// a known LSP that's not installed, AND an installer for it is available.
/// Dismissal is per-language and persisted in `AppConfig.code.dismissedInstallNudges`.
struct InstallNudgeBanner: View {
    let appState: AppState
    let absolutePath: String

    @Environment(\.theme) var theme
    @State private var installSheetVisible = false

    var body: some View {
        if let nudge = nudgeData {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(theme.color("fg-dim"))
                Text("Install \(nudge.command) for \(nudge.displayName) support")
                    .font(.system(size: 12.5))
                Spacer()
                installButton(for: nudge)
                Button(action: { dismiss(language: nudge.language) }) {
                    Image(systemName: "xmark")
                        .foregroundColor(theme.color("fg-dim"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.color("bg-1"))
            .overlay(Rectangle()
                .frame(height: 0.5)
                .foregroundColor(theme.color("line")),
                alignment: .bottom)
            .sheet(isPresented: $installSheetVisible, onDismiss: {
                // Interactive dismiss bypasses the sheet's own buttons; reset
                // the installer so the next install starts from .idle.
                appState.lspInstaller.reset()
            }) {
                LSPInstallProgressSheet(installer: appState.lspInstaller) {
                    installSheetVisible = false
                    appState.refreshInstallerHost()
                }
            }
        }
    }

    private struct NudgeData {
        let language: String
        let displayName: String
        let command: String
        let available: [(installer: DetectedInstaller, recipe: InstallRecipe)]
    }

    private var nudgeData: NudgeData? {
        // 1. Resolve language from extension.
        let ext = (absolutePath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        let registry = LanguageServerRegistry(userDefined: appState.config.code.languageServers)
        guard let language = registry.language(forFileExtension: ext) else { return nil }
        // 2. Skip when LSP is available or disabled.
        guard let entry = registry.allEntries().first(where: { $0.language == language }) else { return nil }
        let availability = LanguageServerAvailability()
        guard availability.status(for: entry) == .notInstalled else { return nil }
        // 3. Catalog entry required (curated or user-defined recipes).
        let recipes: [InstallRecipe] = {
            if let curated = RecommendedLanguageCatalog.entry(forLanguage: language) {
                let resolved = curated.resolvedRecipes
                if !resolved.isEmpty { return resolved }
            }
            return appState.config.code.userDefinedRecipes[language] ?? []
        }()
        guard !recipes.isEmpty else { return nil }
        // 4. Installer must be detected.
        let available = appState.installerHost.allAvailable(in: recipes)
        guard !available.isEmpty else { return nil }
        // 5. Not dismissed.
        guard !appState.config.code.dismissedInstallNudges.contains(language) else { return nil }

        let displayName = RecommendedLanguageCatalog.entry(forLanguage: language)?.displayName ?? language
        return NudgeData(language: language, displayName: displayName, command: entry.command, available: available)
    }

    private var installBusy: Bool {
        if case .running = appState.lspInstaller.state { return true } else { return false }
    }

    @ViewBuilder
    private func installButton(for nudge: NudgeData) -> some View {
        InstallSplitButton(
            recipes: nudge.available.map(\.recipe),
            available: nudge.available,
            busy: installBusy,
            onInstall: { installer, recipe in
                runInstall(installer, recipe: recipe, language: nudge.language)
            }
        )
    }

    private func runInstall(_ installer: DetectedInstaller, recipe: InstallRecipe, language: String) {
        installSheetVisible = true
        Task {
            try? await appState.lspInstaller.install(recipe: recipe, using: installer, language: language)
        }
    }

    private func dismiss(language: String) {
        var dismissed = appState.config.code.dismissedInstallNudges
        if !dismissed.contains(language) {
            dismissed.append(language)
            appState.config.code.dismissedInstallNudges = dismissed
            appState.saveConfig()
        }
    }
}
