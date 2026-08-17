import SwiftUI

struct WarningCharactersSheet: View {
    @Binding var warnings: [WarningCharacter]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: WarningCharacter.ID?
    @State private var code = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Warning Characters").font(.title2.bold())
            Text("Alas highlights invisible or ambiguous characters in red.").foregroundStyle(.secondary)
            List(selection: $selection) { ForEach(warnings) { warning in HStack { Text(warning.code).monospaced(); Text(warning.note) }.tag(warning.id) } }
            HStack { TextField("U+200B or character", text: $code); TextField("Note", text: $note); Button("Add") { if let warning = WarningCharacter.parse(code, note: note), !warnings.contains(where: { $0.id == warning.id }) { warnings.append(warning); code = ""; note = "" } }.disabled(WarningCharacter.parse(code, note: note) == nil) }
            HStack { Button("Remove") { warnings.removeAll { $0.id == selection }; selection = nil }.disabled(selection == nil); Button("Restore Defaults") { warnings = WarningCharacter.defaults }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding().frame(minWidth: 560, minHeight: 420)
    }
}
