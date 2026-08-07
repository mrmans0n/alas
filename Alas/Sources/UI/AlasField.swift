import SwiftUI
import AppKit

struct AlasField: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false
    var focusOnAppear: Bool = false
    var onSubmit: (() -> Void)? = nil
    var leadingIcon: String? = nil
    var inputFilter: GitRefNameInputFilter? = nil
    var isEnabled: Bool = true
    @Environment(\.theme) var theme

    var body: some View {
        if focusOnAppear || onSubmit != nil || inputFilter != nil {
            AlasNSTextField(
                text: $text,
                placeholder: placeholder,
                monospaced: monospaced,
                focusOnAppear: focusOnAppear,
                onSubmit: onSubmit,
                inputFilter: inputFilter,
                isEnabled: isEnabled
            )
            .alasFieldChrome(theme: theme)
        } else {
            let field = TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundColor(theme.color("fg"))
                .disabled(!isEnabled)

            if let leadingIcon = leadingIcon {
                HStack(spacing: 6) {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(theme.color("fg-dim"))
                        .accessibilityHidden(true)
                    field
                }
                .alasFieldChrome(theme: theme)
            } else {
                field
                    .alasFieldChrome(theme: theme)
            }
        }
    }
}

extension View {
    func alasFieldChrome(theme: Theme) -> some View {
        padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct AlasNSTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var monospaced: Bool
    var focusOnAppear: Bool
    var onSubmit: (() -> Void)?
    var inputFilter: GitRefNameInputFilter?
    var isEnabled: Bool

    func makeNSView(context: Context) -> AlasNSTextFieldView {
        let field = AlasNSTextFieldView()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 12, weight: .regular)
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.stringValue = text
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.action(_:))
        field.focusOnAppear = focusOnAppear
        field.isEnabled = isEnabled
        return field
    }

    func updateNSView(_ nsView: AlasNSTextFieldView, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = isEnabled
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if focusOnAppear, nsView.focusOnAppear, let window = nsView.window {
            if window.firstResponder !== nsView {
                window.makeFirstResponder(nsView)
            }
            nsView.focusOnAppear = false
            DispatchQueue.main.async {
                guard let editor = window.fieldEditor(false, for: nsView) as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: nsView.stringValue.count, length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AlasNSTextField

        init(_ parent: AlasNSTextField) {
            self.parent = parent
        }

        @objc func action(_ sender: NSTextField) {
            let value = parent.inputFilter?.sanitize(sender.stringValue, mode: .editing) ?? sender.stringValue
            if sender.stringValue != value {
                sender.stringValue = value
            }
            if value != parent.text {
                parent.text = value
            }
            parent.onSubmit?()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let value = parent.inputFilter?.sanitize(field.stringValue, mode: .editing) ?? field.stringValue
            if field.stringValue != value {
                field.stringValue = value
            }
            if value != parent.text {
                parent.text = value
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            shouldChangeCharactersIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let inputFilter = parent.inputFilter, let replacementString else { return true }

            let proposed = (textView.string as NSString)
                .replacingCharacters(in: affectedCharRange, with: replacementString)
            let sanitized = inputFilter.applyingReplacement(
                to: textView.string,
                range: affectedCharRange,
                replacement: replacementString
            )
            guard sanitized != proposed else { return true }

            textView.string = sanitized
            let insertionLocation = min(
                (sanitized as NSString).length,
                affectedCharRange.location + (replacementString as NSString).length
            )
            textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
            if let field = control as? NSTextField {
                field.stringValue = sanitized
            }
            parent.text = sanitized
            return false
        }
    }
}

private class AlasNSTextFieldView: NSTextField {
    var focusOnAppear = false
}
