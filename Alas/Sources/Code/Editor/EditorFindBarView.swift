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
        HStack(spacing: showsReplace ? 4 : 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.color("fg-muted"))
                    .font(.system(size: 11))
                TextField("Find", text: $findText)
                    .focused($findFieldFocused)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .frame(minWidth: 36, idealWidth: showsReplace ? 120 : 180, maxWidth: .infinity)
                    .layoutPriority(2)
                    .onSubmit { onFind(.next) }
                    .onChange(of: findText) { _ in
                        onFindChanged()
                    }
            }
            .padding(.horizontal, showsReplace ? 6 : 8)
            .padding(.vertical, 4)
            .background(theme.color("bg-2"))
            .cornerRadius(6)

            if showsReplace {
                HStack(spacing: 4) {
                    TextField("Replace", text: $replaceText)
                        .focused($replaceFieldFocused)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12))
                        .frame(minWidth: 36, idealWidth: 120, maxWidth: .infinity)
                        .layoutPriority(1)
                        .onSubmit { onReplace() }
                }
                .padding(.horizontal, 6)
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
                .accessibilityLabel("Previous match")
                .disabled(findText.isEmpty)

                Button(action: { onFind(.next) }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .help("Next match")
                .accessibilityLabel("Next match")
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
            .accessibilityLabel("Match case")
            .accessibilityValue(isCaseSensitive ? "On" : "Off")

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, idealWidth: showsReplace ? 52 : 90, maxWidth: showsReplace ? 64 : 100, alignment: .trailing)

            if showsReplace {
                Button {
                    onReplace()
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Replace current match")
                .accessibilityLabel("Replace current match")
                .disabled(!canReplace)

                Button {
                    onReplaceAll()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Replace all matches")
                .accessibilityLabel("Replace all matches")
                .disabled(!canReplace)
            }

            Button(action: onDone) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Close")
            .accessibilityLabel("Close find bar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
