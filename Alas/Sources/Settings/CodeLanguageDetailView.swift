import SwiftUI

struct CodeLanguageDetailView: View {
    @State var entry: LanguageServerConfig
    let onSave: (LanguageServerConfig) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) var theme

    init(initial: LanguageServerConfig,
         onSave: @escaping (LanguageServerConfig) -> Void,
         onCancel: @escaping () -> Void) {
        _entry = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.language.isEmpty ? "Add language" : "Edit \(entry.language)")
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 12)

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

            HStack(spacing: 8) {
                Spacer()
                AlasButton(title: "Cancel", style: .subtle, action: onCancel)
                AlasButton(title: "Save", style: .primary, action: { onSave(entry) })
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 560)
        .background(theme.color("bg-1"))
    }
}
