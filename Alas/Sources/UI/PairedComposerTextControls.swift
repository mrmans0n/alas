import AppKit
import SwiftUI

class PairedDelimiterTextView: NSTextView {
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !hasMarkedText(), let insertedText = Self.plainText(from: insertString) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        switch PairedDelimiterEditing.resolve(insertedText: insertedText, in: string, selectedRange: range) {
        case let .wrap(opening, closing):
            guard let textStorage, Self.isValid(range, in: textStorage) else {
                super.insertText(insertString, replacementRange: replacementRange)
                return
            }

            let replacement = NSMutableAttributedString(
                string: String(opening),
                attributes: typingAttributes
            )
            replacement.append(textStorage.attributedSubstring(from: range))
            replacement.append(NSAttributedString(
                string: String(closing),
                attributes: typingAttributes
            ))
            super.insertText(replacement, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + 1, length: range.length))

        case let .insertPair(opening, closing):
            let replacement = NSAttributedString(
                string: String(opening) + String(closing),
                attributes: typingAttributes
            )
            super.insertText(replacement, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + 1, length: 0))

        case .stepOver:
            setSelectedRange(NSRange(location: range.location + 1, length: 0))

        case .native:
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    private static func plainText(from value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private static func isValid(_ range: NSRange, in storage: NSTextStorage) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= storage.length
            && range.length <= storage.length - range.location
    }
}

struct PairedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var textColor: NSColor
    var isEnabled: Bool
    var isFocused: Binding<Bool>?
    var onSubmit: (() -> Void)?

    init(
        text: Binding<String>,
        placeholder: String = "",
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        textColor: NSColor = .labelColor,
        isEnabled: Bool = true,
        isFocused: Binding<Bool>? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.font = font
        self.textColor = textColor
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PairedTextFieldBackingView {
        let field = PairedTextFieldBackingView()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.onWindowChanged = { [weak coordinator = context.coordinator, weak field] in
            guard let field else { return }
            coordinator?.synchronizeFocus(for: field)
        }
        applyConfiguration(to: field, coordinator: context.coordinator)
        return field
    }

    func updateNSView(_ field: PairedTextFieldBackingView, context: Context) {
        context.coordinator.parent = self
        applyConfiguration(to: field, coordinator: context.coordinator)
        context.coordinator.synchronizeFocus(for: field)
    }

    static func dismantleNSView(_ field: PairedTextFieldBackingView, coordinator: Coordinator) {
        field.onWindowChanged = nil
        field.delegate = nil
        field.target = nil
    }

    private func applyConfiguration(to field: NSTextField, coordinator: Coordinator) {
        field.placeholderString = placeholder
        field.font = font
        field.textColor = textColor
        field.isEnabled = isEnabled
        field.isEditable = isEnabled
        field.isSelectable = isEnabled

        let fieldEditor = coordinator.fieldEditor(for: field)
        if field.stringValue != text {
            field.stringValue = text
        }
        if let fieldEditor, fieldEditor.string != text {
            let selection = fieldEditor.selectedRange()
            fieldEditor.string = text
            fieldEditor.setSelectedRange(Self.clamped(selection, in: text))
        }
        fieldEditor?.font = font
        fieldEditor?.textColor = textColor
    }

    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PairedTextField
        private var isApplyingPairedEdit = false

        init(_ parent: PairedTextField) {
            self.parent = parent
        }

        @objc func submit(_ sender: NSTextField) {
            updateText(sender.stringValue)
            parent.onSubmit?()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            updateText(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            updateFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            updateFocus(false)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            shouldChangeCharactersIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplyingPairedEdit,
                  parent.isEnabled,
                  !textView.hasMarkedText(),
                  let replacementString
            else { return true }

            switch PairedDelimiterEditing.resolve(
                insertedText: replacementString,
                in: textView.string,
                selectedRange: affectedCharRange
            ) {
            case let .wrap(opening, closing):
                guard let textStorage = textView.textStorage,
                      Self.isValid(affectedCharRange, in: textStorage)
                else { return true }

                let replacement = NSMutableAttributedString(
                    string: String(opening),
                    attributes: textView.typingAttributes
                )
                replacement.append(textStorage.attributedSubstring(from: affectedCharRange))
                replacement.append(NSAttributedString(
                    string: String(closing),
                    attributes: textView.typingAttributes
                ))
                apply(replacement, to: textView, range: affectedCharRange)
                textView.setSelectedRange(NSRange(
                    location: affectedCharRange.location + 1,
                    length: affectedCharRange.length
                ))
                return false

            case let .insertPair(opening, closing):
                let replacement = NSAttributedString(
                    string: String(opening) + String(closing),
                    attributes: textView.typingAttributes
                )
                apply(replacement, to: textView, range: affectedCharRange)
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                return false

            case .stepOver:
                textView.setSelectedRange(NSRange(location: affectedCharRange.location + 1, length: 0))
                return false

            case .native:
                return true
            }
        }

        func synchronizeFocus(for field: NSTextField) {
            guard let binding = parent.isFocused, let window = field.window else { return }
            let editor = fieldEditor(for: field)
            let ownsFocus = window.firstResponder === field || window.firstResponder === editor
            let wantsFocus = binding.wrappedValue && parent.isEnabled

            if wantsFocus, !ownsFocus {
                window.makeFirstResponder(field)
            } else if !wantsFocus, ownsFocus {
                window.makeFirstResponder(nil)
            }
        }

        func fieldEditor(for field: NSTextField) -> NSTextView? {
            guard let window = field.window,
                  window.firstResponder === field || window.firstResponder === window.fieldEditor(false, for: field)
            else { return nil }
            return window.fieldEditor(false, for: field) as? NSTextView
        }

        private func apply(_ replacement: NSAttributedString, to textView: NSTextView, range: NSRange) {
            isApplyingPairedEdit = true
            defer { isApplyingPairedEdit = false }
            textView.insertText(replacement, replacementRange: range)
        }

        private func updateText(_ value: String) {
            if parent.text != value {
                parent.text = value
            }
        }

        private func updateFocus(_ value: Bool) {
            if let binding = parent.isFocused, binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }

        private static func isValid(_ range: NSRange, in storage: NSTextStorage) -> Bool {
            range.location != NSNotFound
                && range.location >= 0
                && range.length >= 0
                && range.location <= storage.length
                && range.length <= storage.length - range.location
        }
    }
}

struct PairedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var isEnabled: Bool
    var isFocused: Binding<Bool>?
    var textContainerInset: NSSize

    init(
        text: Binding<String>,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        textColor: NSColor = .labelColor,
        isEnabled: Bool = true,
        isFocused: Binding<Bool>? = nil,
        textContainerInset: NSSize = .zero
    ) {
        _text = text
        self.font = font
        self.textColor = textColor
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.textContainerInset = textContainerInset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = PairedTextEditorBackingView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.onWindowChanged = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.synchronizeFocus(for: textView)
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyConfiguration(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PairedDelimiterTextView else { return }
        applyConfiguration(to: textView)
        context.coordinator.synchronizeFocus(for: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? PairedTextEditorBackingView else { return }
        textView.onWindowChanged = nil
        textView.delegate = nil
        coordinator.textView = nil
    }

    private func applyConfiguration(to textView: PairedDelimiterTextView) {
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(Self.clamped(selection, in: text))
        }
        textView.font = font
        textView.textColor = textColor
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.textContainerInset = textContainerInset
    }

    private static func clamped(_ range: NSRange, in text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PairedTextEditor
        weak var textView: PairedDelimiterTextView?

        init(_ parent: PairedTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  parent.text != textView.string
            else { return }
            parent.text = textView.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            updateFocus(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            updateFocus(false)
        }

        func synchronizeFocus(for textView: NSTextView) {
            guard let binding = parent.isFocused, let window = textView.window else { return }
            let ownsFocus = window.firstResponder === textView
            let wantsFocus = binding.wrappedValue && parent.isEnabled

            if wantsFocus, !ownsFocus {
                window.makeFirstResponder(textView)
            } else if !wantsFocus, ownsFocus {
                window.makeFirstResponder(nil)
            }
        }

        private func updateFocus(_ value: Bool) {
            if let binding = parent.isFocused, binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }
    }
}

final class PairedTextFieldBackingView: NSTextField {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}

private final class PairedTextEditorBackingView: PairedDelimiterTextView {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}
