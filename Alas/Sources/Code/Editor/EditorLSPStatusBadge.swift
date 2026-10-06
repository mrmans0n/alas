import SwiftUI

struct EditorLSPStatusBadge: View {
    let status: EditorLSPStatus
    /// When `false`, the override picker is hidden everywhere in the popover.
    /// External editor tabs (SDK files opened via cmd-click) pass `false`
    /// because `EditorBuffer.applyEffectiveLanguageToLSP` bails for
    /// `isExternal == true`, so an override pick wouldn't actually re-route
    /// LSP — better to hide the no-op action than to mislead.
    var supportsOverride: Bool = true
    let availableLanguages: () -> [(language: String, displayName: String)]
    let openFilesUsingLanguage: Int
    let onRestart: () -> Void
    let onOverride: (String) -> Void
    let onOpenSettings: () -> Void
    let onInstall: () -> Void

    @State private var popoverOpen: Bool = false
    @State private var resolvedLanguages: [(language: String, displayName: String)] = []

    var body: some View {
        let badge = status.badgeState
        Button { popoverOpen.toggle() } label: {
            LSPStatusPill(state: badge, isHighlighted: popoverOpen)
        }
        .buttonStyle(.plain)
        .help(badge.tooltip)
        .accessibilityLabel(Text("Language server status: \(badge.tooltip)"))
        .accessibilityHint(Text("Shows actions for this file's language server"))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            popoverBody.padding(10).frame(width: 280)
        }
    }

    @ViewBuilder
    private var overridePicker: some View {
        if supportsOverride {
            EditorLSPStatusOverridePicker(
                availableLanguages: resolvedLanguages,
                onPick: { onOverride($0)
                popoverOpen = false },
                onOpenSettings: { onOpenSettings()
                popoverOpen = false }
            )
            .onAppear {
                // Recompute on each popover open so settings changes (server
                // installed/enabled/disabled) show up without recreating the
                // tab. The manager memoizes the underlying availability probe,
                // so this is cheap.
                resolvedLanguages = availableLanguages()
            }
        }
    }

    @ViewBuilder
    private var popoverBody: some View {
        switch status {
        case .ready(let lang, let cmd):
            readyBody(language: lang, command: cmd)
        case .loading(let lang):
            loadingBody(language: lang)
        case .indexing(let lang, _, _, let tasks):
            indexingBody(language: lang, tasks: tasks)
        case .problem(let lang, let kind, let cmd):
            problemBody(language: lang, kind: kind, command: cmd)
        case .noLanguage(let ext):
            noLanguageBody(fileExtension: ext)
        }
    }

    private func readyBody(language: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(language) · \(command)").font(.system(size: 11, weight: .semibold))
            Text("Connected. Document is open and synced.").font(.system(size: 11))
            HStack(spacing: 8) {
                Button(restartLabel(language: language)) { onRestart()
                popoverOpen = false }
                Button("Open settings") { onOpenSettings()
                popoverOpen = false }
            }
            Divider()
            overridePicker
        }
    }

    private func loadingBody(language: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language).font(.system(size: 11, weight: .semibold))
            Text("Starting…").font(.system(size: 11))
            Button("Open settings") {
                onOpenSettings()
                popoverOpen = false
            }
        }
    }

    private func indexingBody(language: String, tasks: [LSPClient.ProgressTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(language) · indexing").font(.system(size: 11, weight: .semibold))
            LSPServerStatusDetail(phase: .indexing(tasks))
            HStack(spacing: 8) {
                Button(restartLabel(language: language)) { onRestart()
                popoverOpen = false }
                Button("Open settings") { onOpenSettings()
                popoverOpen = false }
            }
        }
    }

    @ViewBuilder
    private func problemBody(language: String, kind: ProblemKind, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language).font(.system(size: 11, weight: .semibold))
            switch kind {
            case .notInstalled:
                Text("Language server not installed.").font(.system(size: 11))
                HStack {
                    Button("Install…") { onInstall()
                    popoverOpen = false }
                    Button("Open settings") { onOpenSettings()
                    popoverOpen = false }
                }
                Divider()
                overridePicker
            case .dead(let detail):
                Text("Server crashed.").font(.system(size: 11))
                if let detail {
                    LSPServerStatusDetail(phase: .crashed(detail))
                }
                HStack {
                    Button(restartLabel(language: language)) { onRestart()
                    popoverOpen = false }
                    Button("Open settings") { onOpenSettings()
                    popoverOpen = false }
                }
                Divider()
                overridePicker
            case .disabled:
                Text("Disabled in settings.").font(.system(size: 11))
                Button("Open settings") { onOpenSettings()
                popoverOpen = false }
            }
        }
    }

    private func noLanguageBody(fileExtension ext: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ext.isEmpty ? "Plain text" : ".\(ext)")
                .font(.system(size: 11, weight: .semibold))
            Text("No language server for this file. Treat as another language?")
                .font(.system(size: 11))
            overridePicker
        }
    }

    private func restartLabel(language: String) -> String {
        if openFilesUsingLanguage > 1 {
            return "Restart \(language) (affects \(openFilesUsingLanguage) open files)"
        }
        return "Restart server"
    }
}
