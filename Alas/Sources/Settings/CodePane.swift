import SwiftUI

struct CodePane: View {
    @Bindable var state: AppState
    @Environment(\.theme) var theme

    @State private var selected: LanguageServerConfig?
    @State private var creatingNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Code").font(.system(size: 18, weight: .semibold))
                Text("Syntax highlighting and language servers for editor panes.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)

                SettingsGroup(title: "Languages") {
                    ForEach(allEntries(), id: \.id) { entry in
                        SettingsRow(name: entry.language,
                                    desc: entry.extensions.joined(separator: ", ")) {
                            HStack(spacing: 8) {
                                statusBadge(for: entry)
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
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .sheet(item: $selected) { entry in
            CodeLanguageDetailView(initial: entry,
                                   onSave: save,
                                   onCancel: { selected = nil })
        }
        .sheet(isPresented: $creatingNew) {
            CodeLanguageDetailView(initial: blank(),
                                   onSave: save,
                                   onCancel: { creatingNew = false })
        }
    }

    private func allEntries() -> [LanguageServerConfig] {
        let registry = LanguageServerRegistry(userDefined: state.config.code.languageServers)
        return registry.allEntries()
    }

    // NOTE: `isExecutableFile` returns false for bare names like "sourcekit-lsp"
    // that rely on PATH lookup, so PATH-resolved entries currently render as
    // "Not installed" even when they work. v1: acceptable; revisit by spawning
    // `which` or searching PATH ourselves.
    private func statusBadge(for entry: LanguageServerConfig) -> some View {
        let label: String
        let color: Color
        if !entry.enabled {
            label = "Disabled"; color = theme.color("fg-faint")
        } else if FileManager.default.isExecutableFile(atPath: entry.command) {
            label = "Available"; color = theme.color("add")
        } else {
            label = "Not installed"; color = theme.color("warn")
        }
        return Text(label).font(.system(size: 10.5)).foregroundColor(color)
    }

    private func save(_ entry: LanguageServerConfig) {
        var list = state.config.code.languageServers
        if let i = list.firstIndex(where: { $0.language == entry.language }) {
            list[i] = entry
        } else {
            list.append(entry)
        }
        state.config.code.languageServers = list
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
