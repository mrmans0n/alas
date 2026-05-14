import SwiftUI
import AppKit

struct AlasField: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false
    var focusOnAppear: Bool = false
    var onSubmit: (() -> Void)? = nil
    @Environment(\.theme) var theme

    var body: some View {
        if focusOnAppear || onSubmit != nil {
            AlasNSTextField(
                text: $text,
                placeholder: placeholder,
                monospaced: monospaced,
                focusOnAppear: focusOnAppear,
                onSubmit: onSubmit
            )
            .frame(height: 28)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(theme.color("bg-1"))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .foregroundColor(theme.color("fg"))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct AlasNSTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var monospaced: Bool
    var focusOnAppear: Bool
    var onSubmit: (() -> Void)?

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
        return field
    }

    func updateNSView(_ nsView: AlasNSTextFieldView, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if focusOnAppear, nsView.focusOnAppear, let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
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
            if sender.stringValue != parent.text {
                parent.text = sender.stringValue
            }
            parent.onSubmit?()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if field.stringValue != parent.text {
                parent.text = field.stringValue
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? AlasNSTextFieldView, field.focusOnAppear else { return }
            field.focusOnAppear = false
            DispatchQueue.main.async {
                guard let editor = field.window?.fieldEditor(false, for: field) as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: field.stringValue.count, length: 0))
            }
        }
    }
}

private class AlasNSTextFieldView: NSTextField {
    var focusOnAppear = false
}
