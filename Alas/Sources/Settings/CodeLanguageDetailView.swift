import SwiftUI

// Stub form, expanded in the next commit. Wired now so CodePane builds.
struct CodeLanguageDetailView: View {
    @State var entry: LanguageServerConfig
    let onSave: (LanguageServerConfig) -> Void
    let onCancel: () -> Void

    init(initial: LanguageServerConfig,
         onSave: @escaping (LanguageServerConfig) -> Void,
         onCancel: @escaping () -> Void) {
        _entry = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack {
            Text(entry.language.isEmpty ? "Add language" : "Edit \(entry.language)")
            HStack {
                AlasButton(title: "Cancel", action: onCancel)
                AlasButton(title: "Save", action: { onSave(entry) })
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
