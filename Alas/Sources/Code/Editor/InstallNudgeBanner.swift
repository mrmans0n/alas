import SwiftUI

/// A non-blocking banner shown above the editor when the file's language has
/// a known LSP that's not installed, AND an installer for it is available.
/// Dismissal is per-language and persisted in `AppConfig.code.dismissedInstallNudges`.
struct InstallNudgeBanner: View {
    let appState: AppState
    let absolutePath: String

    @Environment(\.theme) var theme
    @State private var installSheetVisible = false
    @State private var selectedMasonPackageId: String?
    @State private var pendingMasonPackage: MasonPackage?

    var body: some View {
        // The sheet modifier is attached to the OUTER container (always
        // mounted) rather than the inner conditional banner. When the
        // install succeeds, availability flips to .available, `nudgeData`
        // returns nil, and the banner unmounts — if the sheet lived on the
        // banner, SwiftUI would silently dismiss it and fire onDismiss
        // instead of the sheet's own Done/Close callback, skipping the
        // refresh + reopen-LSP path for the very install that just
        // completed.
        Group {
            if let nudge = nudgeData {
                bannerRow(nudge: nudge)
            }
        }
        .sheet(isPresented: $installSheetVisible, onDismiss: {
            // Interactive dismiss bypasses the sheet's own buttons; reset
            // the installer so the next install starts from .idle.
            pendingMasonPackage = nil
            appState.lspInstaller.reset()
        }) {
            LSPInstallProgressSheet(installer: appState.lspInstaller) { completedLanguage in
                installSheetVisible = false
                appState.refreshInstallerHost()
                // Re-fire didOpen for any open buffers in the just-
                // installed language so hover/diagnostics/definitions
                // wake up without a manual close-and-reopen.
                if let completedLanguage {
                    if let package = pendingMasonPackage {
                        let config = LanguageServerConfig.prefilled(from: package)
                        appState.config.code.saveLanguageServerConfig(
                            originalLanguage: nil,
                            config,
                            recipes: package.recipes
                        )
                        appState.saveConfig()
                        appState.tabs.reopenLSPDocuments(
                            forFileExtensions: package.extensions,
                            language: completedLanguage
                        )
                    } else {
                        appState.tabs.reopenLSPDocuments(forLanguage: completedLanguage)
                    }
                }
                pendingMasonPackage = nil
            }
        }
    }

    private func bannerRow(nudge: InstallNudgeData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(theme.color("fg-dim"))
            Text("Install \(nudge.command) for \(nudge.displayName) support")
                .font(.system(size: 12.5))
            Spacer()
            masonPicker(for: nudge)
            installButton(for: nudge)
            Button(action: { dismiss(key: nudge.dismissalKey) }) {
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
    }

    private var nudgeData: InstallNudgeData? {
        let registry = LanguageServerRegistry(userDefined: appState.config.code.languageServers)
        let resolver = InstallNudgeResolver(
            registry: registry,
            userDefinedRecipes: appState.config.code.userDefinedRecipes,
            dismissedInstallNudges: appState.config.code.dismissedInstallNudges,
            installerHost: appState.installerHost
        )
        return resolver
            .nudgeData(forAbsolutePath: absolutePath)?
            .selectingMasonOption(id: selectedMasonPackageId)
    }

    private var installBusy: Bool {
        if case .running = appState.lspInstaller.state { return true } else { return false }
    }

    @ViewBuilder
    private func masonPicker(for nudge: InstallNudgeData) -> some View {
        if nudge.masonOptions.count > 1 {
            Picker("", selection: Binding(
                get: {
                    if let selectedMasonPackageId,
                       nudge.masonOptions.contains(where: { $0.id == selectedMasonPackageId }) {
                        return selectedMasonPackageId
                    }
                    return nudge.masonPackage?.masonId ?? ""
                },
                set: { selectedMasonPackageId = $0 }
            )) {
                ForEach(nudge.masonOptions) { option in
                    Text(option.displayName).tag(option.package.masonId)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
        }
    }

    @ViewBuilder
    private func installButton(for nudge: InstallNudgeData) -> some View {
        InstallSplitButton(
            recipes: nudge.available.map(\.recipe),
            available: nudge.available,
            busy: installBusy,
            onInstall: { installer, recipe in
                runInstall(installer, recipe: recipe, language: nudge.language, masonPackage: nudge.masonPackage)
            }
        )
    }

    private func runInstall(_ installer: DetectedInstaller, recipe: InstallRecipe, language: String, masonPackage: MasonPackage?) {
        pendingMasonPackage = masonPackage
        installSheetVisible = true
        Task {
            try? await appState.lspInstaller.install(recipe: recipe, using: installer, language: language)
        }
    }

    private func dismiss(key: String) {
        var dismissed = appState.config.code.dismissedInstallNudges
        if !dismissed.contains(key) {
            dismissed.append(key)
            appState.config.code.dismissedInstallNudges = dismissed
            appState.saveConfig()
        }
    }
}
