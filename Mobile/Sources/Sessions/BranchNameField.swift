import AlasRemoteKit
import SwiftUI
import UIKit

/// Filters the inserted text before UIKit replaces the user's selection.
struct BranchNameField: UIViewRepresentable {
    @Binding var text: String
    var placeholder = "New branch"

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.accessibilityLabel = "New branch"
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
                        for: [.editingChanged, .editingDidEnd])
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        field.isEnabled = context.environment.isEnabled
        field.placeholder = placeholder
        if field.markedTextRange == nil, field.text != text {
            field.text = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                       replacementString input: String) -> Bool {
            guard field.markedTextRange == nil else { return true }
            let normalized = GitNameValidator.normalizedBranchNameInput(input)
            guard normalized != input else { return true }
            let start = field.beginningOfDocument
            guard !normalized.isEmpty,
                  let from = field.position(from: start, offset: range.location),
                  let to = field.position(from: from, offset: range.length),
                  let replacement = field.textRange(from: from, to: to) else { return false }
            field.replace(replacement, withText: normalized)
            if let caret = field.position(from: field.beginningOfDocument, offset: range.location + normalized.utf16.count) {
                field.selectedTextRange = field.textRange(from: caret, to: caret)
            }
            editingChanged(field)
            return false
        }

        @objc func editingChanged(_ field: UITextField) {
            guard field.markedTextRange == nil, let value = field.text else { return }
            let normalized = GitNameValidator.normalizedBranchNameInput(value)
            if normalized != value {
                // An input method can commit marked text without asking the delegate.
                let oldCaret = field.selectedTextRange?.end
                let start = field.beginningOfDocument
                let offset = oldCaret.map { field.offset(from: start, to: $0) } ?? value.utf16.count
                let beforeCaret = String(decoding: value.utf16.prefix(offset), as: UTF16.self)
                let newOffset = GitNameValidator.normalizedBranchNameInput(beforeCaret).utf16.count
                field.text = normalized
                if let caret = field.position(from: field.beginningOfDocument, offset: newOffset) {
                    field.selectedTextRange = field.textRange(from: caret, to: caret)
                }
            }
            text.wrappedValue = normalized
        }
    }
}
