import SwiftUI

struct CodeLanguageDetailView: View {
    @Environment(\.designScale) private var scale
    @State private var model: CodeLanguageDetailModel
    let isNew: Bool
    private let defaultInlayHints: InlayHintSettings

    @Environment(\.theme) var theme
    @State private var prefillQuery: String = ""

    init(initial: LanguageServerConfig,
         isNew: Bool,
         inlayHints: Binding<InlayHintSettings?> = .constant(nil),
         defaultInlayHints: InlayHintSettings = .init(),
         onSave: @escaping (LanguageServerConfig, [InstallRecipe]?) -> Void,
         onCancel: @escaping () -> Void) {
        _model = State(initialValue: CodeLanguageDetailModel(initial: initial, inlayHints: inlayHints, onSave: onSave, onCancel: onCancel))
        self.isNew = isNew
        self.defaultInlayHints = defaultInlayHints
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.entry.language.isEmpty ? "Add language" : "Edit \(model.entry.language)")
                .font(SettingsPaneStyle.titleFont)
                .padding(.bottom, scale.space[3])

            if isNew {
                Text("Start from a known LSP")
                    .font(scale.titleFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, scale.space[2])

                AlasField(
                    text: $prefillQuery,
                    placeholder: "Search LSP packages…",
                    monospaced: false,
                    leadingIcon: "magnifyingglass"
                )
                .padding(.bottom, scale.space[2])

                let results = MasonSnapshot.shared.search(prefillQuery)
                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(results.prefix(6)) { pkg in
                            Button(action: { applyPrefill(pkg) }) {
                                HStack(spacing: 8) {
                                    Text(pkg.displayName)
                                        .font(scale.metaFont)
                                    Text("·")
                                        .foregroundColor(theme.color("fg-faint"))
                                    Text(pkg.languages.joined(separator: ", "))
                                        .font(scale.metaFont)
                                        .foregroundColor(theme.color("fg-dim"))
                                    Spacer()
                                }
                                .padding(.vertical, scale.space[1])
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, scale.space[3])
                } else if !prefillQuery.isEmpty {
                    Text("No matches")
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.bottom, scale.space[3])
                }

                Divider().padding(.bottom, scale.space[3])
            }

            SettingsRow(name: "Language ID") {
                AlasField(text: $model.entry.language, monospaced: true)
            }
            SettingsRow(name: "File extensions",
                        desc: "Comma-separated, e.g. swift, swiftinterface") {
                AlasField(text: Binding(
                    get: { model.entry.extensions.joined(separator: ", ") },
                    set: {
                        model.entry.extensions = $0.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                ), monospaced: true)
            }
            SettingsRow(name: "Command") {
                AlasField(text: $model.entry.command, monospaced: true)
            }
            SettingsRow(name: "Args", desc: "One per line.") {
                TextEditor(text: Binding(
                    get: { model.entry.args.joined(separator: "\n") },
                    set: { model.entry.args = $0.split(separator: "\n").map(String.init) }
                ))
                .font(scale.meta.font(design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
                .padding(scale.space[2])
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            SettingsRow(name: "Root markers", desc: "One per line.") {
                TextEditor(text: Binding(
                    get: { model.entry.rootMarkers.joined(separator: "\n") },
                    set: { model.entry.rootMarkers = $0.split(separator: "\n").map(String.init) }
                ))
                .font(scale.meta.font(design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60)
                .padding(scale.space[2])
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5))
            }
            SettingsRow(name: "Enabled") {
                AlasToggle(on: $model.entry.enabled)
            }

            if !isNew {
                SettingsRow(name: "Use default inlay hints") {
                    AlasToggle(on: Binding(get: { model.inlayHints == nil }, set: { model.inlayHints = $0 ? nil : defaultInlayHints }))
                }
                SettingsRow(name: "Show inlay hints") { AlasToggle(on: inlayBinding(\.enabled)).disabled(model.inlayHints == nil) }
                SettingsRow(name: "Parameter names") { AlasToggle(on: inlayBinding(\.parameters)).disabled(model.inlayHints == nil || model.inlayHints?.enabled == false) }
                SettingsRow(name: "Inferred types") { AlasToggle(on: inlayBinding(\.types)).disabled(model.inlayHints == nil || model.inlayHints?.enabled == false) }
            }

            if let validation = validationMessage {
                Text(validation)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("warn"))
                    .padding(.top, scale.space[2])
            }

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: model.cancel)

                AlasButton(
                    title: "Save",
                    style: .primary,
                    action: model.save
                )
                    .disabled(validationMessage != nil)
            }
            .padding(.top, scale.space[4])
        }
        .padding(scale.space[5])
        .frame(width: 560)
        .background(theme.color("bg-1"))
    }

    private func inlayBinding(_ keyPath: WritableKeyPath<InlayHintSettings, Bool>) -> Binding<Bool> {
        Binding(get: { (model.inlayHints ?? defaultInlayHints)[keyPath: keyPath] }, set: {
            var settings = model.inlayHints ?? defaultInlayHints
            settings[keyPath: keyPath] = $0
            model.inlayHints = settings
        })
    }

    private var validationMessage: String? {
        // Mason prefill leaves extensions empty for many packages; without
        // them `LanguageServerRegistry.language(forFileExtension:)` never
        // matches the language and the LSP never spawns. Block save until
        // the required fields are filled.
        if model.entry.language.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Language ID is required."
        }
        if model.entry.command.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Command is required."
        }
        if model.entry.extensions.isEmpty {
            return "Add at least one file extension."
        }
        return nil
    }

    private func applyPrefill(_ pkg: MasonPackage) {
        model.entry = LanguageServerConfig.prefilled(from: pkg)
        model.pendingRecipes = pkg.recipes
    }
}

/// Shared edit session for the sheet's fields and explicit Save/Cancel actions.
@MainActor
@Observable
final class CodeLanguageDetailModel {
    var entry: LanguageServerConfig
    var pendingRecipes: [InstallRecipe]?
    var inlayHints: InlayHintSettings?
    private let hintBinding: Binding<InlayHintSettings?>
    private let onSave: (LanguageServerConfig, [InstallRecipe]?) -> Void
    private let onCancel: () -> Void

    init(initial: LanguageServerConfig, inlayHints: Binding<InlayHintSettings?>,
         onSave: @escaping (LanguageServerConfig, [InstallRecipe]?) -> Void,
         onCancel: @escaping () -> Void) {
        entry = initial
        hintBinding = inlayHints
        self.inlayHints = inlayHints.wrappedValue
        self.onSave = onSave
        self.onCancel = onCancel
    }

    func save() {
        hintBinding.wrappedValue = inlayHints
        onSave(entry.normalizedForSettingsSave(), pendingRecipes)
    }
    func cancel() { onCancel() }
}
