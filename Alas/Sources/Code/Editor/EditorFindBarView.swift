import SwiftUI

struct EditorFindBarView: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var isCaseSensitive: Bool
    @FocusState.Binding var findFieldFocused: Bool
    @FocusState.Binding var replaceFieldFocused: Bool

    let showsReplace: Bool
    let statusText: String
    let canReplace: Bool
    let onFindChanged: () -> Void
    let onToggleCaseSensitive: () -> Void
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
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.color("fg-muted"))
                    .font(.system(size: 11))
                TextField("Find", text: $findText)
                    .focused($findFieldFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .frame(width: 180)
                    .onSubmit { onFind(.next) }
                    .onChange(of: findText) { _ in
                        onFindChanged()
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.color("bg-2"))
            .cornerRadius(6)

            if showsReplace {
                HStack(spacing: 4) {
                    TextField("Replace", text: $replaceText)
                        .focused($replaceFieldFocused)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12))
                        .frame(width: 180)
                        .onSubmit { onReplace() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.color("bg-2"))
                .cornerRadius(6)
            }

            HStack(spacing: 2) {
                Button(action: { onFind(.previous) }) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .help("Previous match")
                .disabled(findText.isEmpty)

                Button(action: { onFind(.next) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .help("Next match")
                .disabled(findText.isEmpty)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                isCaseSensitive.toggle()
                onToggleCaseSensitive()
            }) {
                Text("Aa")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isCaseSensitive ? theme.color("accent") : theme.color("fg-muted"))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Match case")

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)

            if showsReplace {
                Button("Replace") {
                    onReplace()
                }
                .font(.system(size: 11, weight: .medium))
                .disabled(!canReplace)

                Button("All") {
                    onReplaceAll()
                }
                .font(.system(size: 11, weight: .medium))
                .disabled(!canReplace)
            }

            Spacer(minLength: 8)

            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }
}
