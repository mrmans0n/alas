import SwiftUI

struct CodeLanguageDetailView: View {
    @State var entry: LanguageServerConfig
    let isNew: Bool
    let onSave: (LanguageServerConfig, [InstallRecipe]?) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) var theme
    @State private var prefillQuery: String = ""
    @State private var pendingRecipes: [InstallRecipe]? = nil

    init(initial: LanguageServerConfig,
         isNew: Bool,
         onSave: @escaping (LanguageServerConfig, [InstallRecipe]?) -> Void,
         onCancel: @escaping () -> Void) {
        _entry = State(initialValue: initial)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.language.isEmpty ? "Add language" : "Edit \(entry.language)")
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 12)

            if isNew {
                Text("Start from a known LSP")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 6)

                AlasField(text: $prefillQuery, monospaced: false)
                    .padding(.bottom, 6)

                let results = MasonSnapshot.shared.search(prefillQuery)
                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(results.prefix(6)) { pkg in
                            Button(action: { applyPrefill(pkg) }) {
                                HStack(spacing: 8) {
                                    Text(pkg.displayName)
                                        .font(.system(size: 12.5))
                                    Text("·")
                                        .foregroundColor(theme.color("fg-faint"))
                                    Text(pkg.languages.joined(separator: ", "))
                                        .font(.system(size: 11.5))
                                        .foregroundColor(theme.color("fg-dim"))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 12)
                } else if !prefillQuery.isEmpty {
                    Text("No matches")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.bottom, 12)
                }

                Divider().padding(.bottom, 12)
            }

            SettingsRow(name: "Language ID") {
                AlasField(text: $entry.language, monospaced: true)
            }
            SettingsRow(name: "File extensions",
                        desc: "Comma-separated, e.g. swift, swiftinterface") {
                AlasField(text: Binding(
                    get: { entry.extensions.joined(separator: ", ") },
                    set: {
                        entry.extensions = $0.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                ), monospaced: true)
            }
            SettingsRow(name: "Command") {
                AlasField(text: $entry.command, monospaced: true)
            }
            SettingsRow(name: "Args", desc: "One per line.") {
                TextEditor(text: Binding(
                    get: { entry.args.joined(separator: "\n") },
                    set: { entry.args = $0.split(separator: "\n").map(String.init) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
                .padding(8)
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            SettingsRow(name: "Root markers", desc: "One per line.") {
                TextEditor(text: Binding(
                    get: { entry.rootMarkers.joined(separator: "\n") },
                    set: { entry.rootMarkers = $0.split(separator: "\n").map(String.init) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
                .padding(8)
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            SettingsRow(name: "Enabled") {
                AlasToggle(on: $entry.enabled)
            }

            if let validation = validationMessage {
                Text(validation)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.color("warn"))
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: onCancel)
                AlasButton(
                    title: "Save",
                    style: .primary,
                    action: { onSave(entry.normalizedForSettingsSave(), pendingRecipes) }
                )
                    .disabled(validationMessage != nil)
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 560)
        .background(theme.color("bg-1"))
    }

    private var validationMessage: String? {
        // Mason prefill leaves extensions empty for many packages; without
        // them `LanguageServerRegistry.language(forFileExtension:)` never
        // matches the language and the LSP never spawns. Block save until
        // the required fields are filled.
        if entry.language.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Language ID is required."
        }
        if entry.command.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Command is required."
        }
        if entry.extensions.isEmpty {
            return "Add at least one file extension."
        }
        return nil
    }

    private func applyPrefill(_ pkg: MasonPackage) {
        // Prefer the generator-normalized languageId so it lines up with the
        // registry's built-in languageIds (e.g. "shellscript", not "bash";
        // "cpp", not "c++"). Fall back to masonId only when the snapshot has
        // no language data at all.
        let resolved = pkg.languageId.isEmpty ? pkg.masonId.lowercased() : pkg.languageId
        entry.language = resolved
        entry.extensions = pkg.extensions
        entry.command = pkg.command
        entry.args = pkg.args
        pendingRecipes = pkg.recipes
    }
}

extension LanguageServerConfig {
    func normalizedForSettingsSave() -> LanguageServerConfig {
        var normalized = self
        normalized.language = language.trimmingCharacters(in: .whitespaces)
        normalized.command = command.trimmingCharacters(in: .whitespaces)
        normalized.args = args
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        normalized.rootMarkers = rootMarkers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return normalized
    }
}
