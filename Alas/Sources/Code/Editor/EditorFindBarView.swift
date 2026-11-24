import SwiftUI

struct EditorFindBarView: View {
    @Binding var findText: String
    @Binding var isCaseSensitive: Bool
    @FocusState.Binding var findFieldFocused: Bool
    var replacement: Replacement? = nil
    let statusText: String
    private var showsReplace: Bool { replacement != nil }
    let onFind: (_ direction: FindDirection) -> Void
    let onDone: () -> Void

    struct Replacement {
        let text: Binding<String>
        let focused: FocusState<Bool>.Binding
        let canReplace: Bool
        let replace: () -> Void
        let replaceAll: () -> Void
    }

    enum FindDirection {
        case previous
        case next
    }

    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: showsReplace ? 4 : 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.color("fg-muted"))
                    .font(scale.meta.font)
                TextField("Find", text: $findText)
                    .focused($findFieldFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(scale.meta.font)
                    .frame(minWidth: 36, idealWidth: showsReplace ? 120 : 180, maxWidth: .infinity)
                    .layoutPriority(2)
                    .onSubmit { onFind(.next) }
            }
            .padding(.horizontal, showsReplace ? 6 : 8)
            .padding(.vertical, scale.space[1])
            .background(theme.color("bg-2"))
            .cornerRadius(6)

            if let replacement {
                HStack(spacing: 4) {
                    TextField("Replace", text: replacement.text)
                        .focused(replacement.focused)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(scale.meta.font)
                        .frame(minWidth: 36, idealWidth: 120, maxWidth: .infinity)
                        .layoutPriority(1)
                        .onSubmit { replacement.replace() }
                }
                .padding(.horizontal, scale.space[2])
                .padding(.vertical, scale.space[1])
                .background(theme.color("bg-2"))
                .cornerRadius(6)
            }

            HStack(spacing: 2) {
                Button(action: { onFind(.previous) }) {
                    Image(systemName: "chevron.up")
                        .font(scale.glyph.font)
                        .frame(width: 22, height: 22)
                }
                .help("Previous match")
                .accessibilityLabel("Previous match")
                .disabled(findText.isEmpty)

                Button(action: { onFind(.next) }) {
                    Image(systemName: "chevron.down")
                        .font(scale.glyph.font)
                        .frame(width: 22, height: 22)
                }
                .help("Next match")
                .accessibilityLabel("Next match")
                .disabled(findText.isEmpty)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                isCaseSensitive.toggle()
            }) {
                Text("Aa")
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundColor(isCaseSensitive ? theme.color("accent") : theme.color("fg-muted"))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Match case")
            .accessibilityLabel("Match case")
            .accessibilityValue(isCaseSensitive ? "On" : "Off")

            Text(statusText)
                .font(scale.meta.font)
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, idealWidth: showsReplace ? 52 : 90, maxWidth: showsReplace ? 64 : 100, alignment: .trailing)

            if let replacement {
                Button {
                    replacement.replace()
                } label: {
                    Image(systemName: "arrow.right")
                        .font(scale.glyph.font)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Replace current match")
                .accessibilityLabel("Replace current match")
                .disabled(!replacement.canReplace)

                Button {
                    replacement.replaceAll()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(scale.glyph.font)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Replace all matches")
                .accessibilityLabel("Replace all matches")
                .disabled(!replacement.canReplace)
            }

            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(scale.meta.font(weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Close")
            .accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .onExitCommand(perform: onDone)
        .onKeyPress { press in
            handleKeyPress(press)
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            onDone()
            return .handled
        case .return:
            if press.modifiers.contains(.shift) {
                onFind(.previous)
                return .handled
            }
            return .ignored
        default:
            return .ignored
        }
    }
}
