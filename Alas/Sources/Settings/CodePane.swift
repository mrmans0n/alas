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
                                   onSave: { save(originalLanguage: entry.language, $0) },
                                   onCancel: { selected = nil })
        }
        .sheet(isPresented: $creatingNew) {
            CodeLanguageDetailView(initial: blank(),
                                   onSave: { save(originalLanguage: nil, $0) },
                                   onCancel: { creatingNew = false })
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
            label = "Disabled"; color = theme.color("fg-faint")
        case .available:
            label = "Available"; color = theme.color("add")
        case .notInstalled:
            label = "Not installed"; color = theme.color("warn")
        }
        return Text(label).font(.system(size: 10.5)).foregroundColor(color)
    }

    private func save(originalLanguage: String?, _ entry: LanguageServerConfig) {
        var list = state.config.code.languageServers
        // Look up by the original language ID so renaming an entry replaces
        // it in place. Searching by the edited value (`entry.language`) would
        // miss the existing config and orphan it — there's no delete action
        // in the Code pane, so the stale entry would stick around and could
        // keep claiming its old extensions.
        let lookupKey = originalLanguage ?? entry.language
        if let i = list.firstIndex(where: { $0.language == lookupKey }) {
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
