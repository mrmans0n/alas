import SwiftUI

struct EditorFindBarView: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var message: String?

    let onFind: (_ direction: FindDirection) -> Void
    let onReplace: () -> Void
    let onReplaceAll: () -> Void
    let onDone: () -> Void

    enum FindDirection {
        case previous
        case next
    }

    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.color("fg-muted"))
                    .font(.system(size: 11))
                TextField("Find", text: $findText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .frame(minWidth: 120)
                    .onSubmit { onFind(.next) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.color("bg-2"))
            .cornerRadius(6)

            HStack(spacing: 4) {
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .frame(minWidth: 120)
                    .onSubmit { onReplace() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.color("bg-2"))
            .cornerRadius(6)

            Button("Replace") {
                onReplace()
            }
            .font(.system(size: 11, weight: .medium))
            .disabled(findText.isEmpty)

            Button("All") {
                onReplaceAll()
            }
            .font(.system(size: 11, weight: .medium))
            .disabled(findText.isEmpty)

            Spacer(minLength: 8)

            if let msg = message {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
            }

            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
