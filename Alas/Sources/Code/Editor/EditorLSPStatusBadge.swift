import SwiftUI

struct EditorLSPStatusBadge: View {
    let status: EditorLSPStatus
    let availableLanguages: () -> [(language: String, displayName: String)]
    let openFilesUsingLanguage: Int
    let onRestart: () -> Void
    let onOverride: (String) -> Void
    let onOpenSettings: () -> Void
    let onCancel: () -> Void
    let onInstall: () -> Void

    @State private var popoverOpen: Bool = false
    @State private var resolvedLanguages: [(language: String, displayName: String)] = []
    @Environment(\.theme) var theme

    var body: some View {
        Button { popoverOpen.toggle() } label: { pill }
            .buttonStyle(.plain)
            .help(tooltip)
            .accessibilityLabel(Text("Language server status: \(tooltip)"))
            .accessibilityHint(Text("Shows actions for this file's language server"))
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $popoverOpen, arrowEdge: .top) {
                popoverBody.padding(10).frame(width: 280)
            }
    }

    private var overridePicker: some View {
        EditorLSPStatusOverridePicker(
            availableLanguages: resolvedLanguages,
            onPick: { onOverride($0); popoverOpen = false },
            onOpenSettings: { onOpenSettings(); popoverOpen = false }
        )
        .onAppear {
            if resolvedLanguages.isEmpty {
                resolvedLanguages = availableLanguages()
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 6) {
            glyph
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-muted"))
            if case .problem = status {
                Text("!")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.color("warn"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(theme.color("bg-2").opacity(popoverOpen ? 1 : 0))
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .ready:
            Circle().fill(theme.color("add")).frame(width: 7, height: 7).accessibilityHidden(true)
        case .loading:
            ProgressView().controlSize(.mini).frame(width: 9, height: 9).accessibilityHidden(true)
        case .problem:
            Circle().fill(theme.color("warn")).frame(width: 7, height: 7).accessibilityHidden(true)
        case .noLanguage:
            Circle().stroke(theme.color("fg-faint"), lineWidth: 1).frame(width: 7, height: 7).accessibilityHidden(true)
        }
    }

    private var label: String {
        switch status {
        case .ready(let language, _),
             .loading(let language),
             .problem(let language, _, _):
            return language
        case .noLanguage(let ext):
            return ext.isEmpty ? "Plain text" : ".\(ext)"
        }
    }

    private var tooltip: String {
        switch status {
        case .ready(let lang, let cmd): return "\(lang) · \(cmd)"
        case .loading(let lang): return "\(lang) · starting…"
        case .problem(let lang, let kind, _):
            let reason: String
            switch kind {
            case .notInstalled: reason = "not installed"
            case .dead:         reason = "crashed"
            case .disabled:     reason = "disabled"
            }
            return "\(lang) · \(reason)"
        case .noLanguage: return "No language server"
        }
    }

    @ViewBuilder
    private var popoverBody: some View {
        switch status {
        case .ready(let lang, let cmd):
            readyBody(language: lang, command: cmd)
        case .loading(let lang):
            loadingBody(language: lang)
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
                Button(restartLabel(language: language)) { onRestart(); popoverOpen = false }
                Button("Open settings") { onOpenSettings(); popoverOpen = false }
            }
            Divider()
            overridePicker
        }
    }

    private func loadingBody(language: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language).font(.system(size: 11, weight: .semibold))
            Text("Starting…").font(.system(size: 11))
            HStack {
                Button("Cancel") { onCancel(); popoverOpen = false }
                Button("Open settings") { onOpenSettings(); popoverOpen = false }
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
                    Button("Install…") { onInstall(); popoverOpen = false }
                    Button("Open settings") { onOpenSettings(); popoverOpen = false }
                }
                Divider()
                overridePicker
            case .dead:
                Text("Server crashed.").font(.system(size: 11))
                HStack {
                    Button(restartLabel(language: language)) { onRestart(); popoverOpen = false }
                    Button("Open settings") { onOpenSettings(); popoverOpen = false }
                }
                Divider()
                overridePicker
            case .disabled:
                Text("Disabled in settings.").font(.system(size: 11))
                Button("Open settings") { onOpenSettings(); popoverOpen = false }
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
