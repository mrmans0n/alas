import SwiftUI

struct RunScriptWritingHelpField: View {
    @Binding var request: String
    @Environment(\.theme) private var theme

    var body: some View {
        DialogField(label: "What should the script do?") {
            TextEditor(text: $request)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg"))
                .scrollContentBackground(.hidden)
                .frame(height: 90)
                .padding(8)
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.5))
                .accessibilityLabel("What should the script do?")
            Text("Opens a draft prompt in a new chat with your default agent.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct RunScriptWritingHelpDialog: View {
    let fileName: String
    let onSubmit: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @State private var errorMessage: String?

    var body: some View {
        DialogContainer(
            title: "Help me write this",
            subtitle: "Save and continue working on \(fileName) with your default agent.",
            content: {
                RunScriptWritingHelpField(request: $request)
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                }
            },
            cancelTitle: "Cancel",
            confirmTitle: "Save and open chat",
            confirmStyle: .primary,
            onCancel: { dismiss() },
            onConfirm: {
                do {
                    try onSubmit(request)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            },
            confirmEnabled: !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
}
