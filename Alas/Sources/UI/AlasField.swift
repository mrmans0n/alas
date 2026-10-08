import SwiftUI
import AppKit

struct AlasField: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false
    var focusOnAppear: Bool = false
    var onSubmit: (() -> Void)? = nil
    var leadingIcon: String? = nil
    var isEnabled: Bool = true
    var disablesAutomaticTextSubstitutions: Bool = false
    var inputPolicy: AlasFieldInputPolicy? = nil
    /// Sees pasted text before the field does; returning true consumes it.
    var onPaste: ((String) -> Bool)? = nil
    @Environment(\.theme) var theme

    var body: some View {
        if focusOnAppear || onSubmit != nil || disablesAutomaticTextSubstitutions || inputPolicy != nil
            || onPaste != nil {
            AlasNSTextField(
                text: $text,
                placeholder: placeholder,
                monospaced: monospaced,
                focusOnAppear: focusOnAppear,
                onSubmit: onSubmit,
                isEnabled: isEnabled,
                disablesAutomaticTextSubstitutions: disablesAutomaticTextSubstitutions,
                inputPolicy: inputPolicy,
                onPaste: onPaste
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

    /// Marks a field whose contents a local model is still computing, or a
    /// control offering a one-click shortcut: the border takes the accent
    /// tint and a short beam of light travels around it. Reduce Motion keeps
    /// only the tint.
    func aiBeam(isActive: Bool, cornerRadius: CGFloat = 6) -> some View {
        overlay {
            if isActive {
                AIBeamBorder(cornerRadius: cornerRadius)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isActive)
    }
}

private struct AIBeamBorder: View {
    let cornerRadius: CGFloat
    /// Seconds per lap, and the share of the perimeter the beam covers.
    private static let period: TimeInterval = 2.4
    private static let length: CGFloat = 0.16
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let accent = theme.color("accent")
        ZStack {
            shape.strokeBorder(accent.opacity(0.35), lineWidth: 1)
            if !reduceMotion {
                // Trimming the outline, rather than rotating an angular
                // gradient, keeps the beam's speed even along a wide field.
                TimelineView(.animation) { timeline in
                    let start = CGFloat(
                        timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: Self.period) / Self.period
                    )
                    ZStack {
                        beam(shape, from: start, color: accent)
                            .blur(radius: 2)
                        beam(shape, from: start, color: accent)
                    }
                }
            }
        }
    }

    /// The trimmed stretch of outline, split in two when it wraps past the
    /// path's origin.
    private func beam(_ shape: RoundedRectangle, from start: CGFloat, color: Color) -> some View {
        let outline = shape.inset(by: 0.75)
        let end = start + Self.length
        let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
        return ZStack {
            outline.trim(from: start, to: min(end, 1)).stroke(color, style: style)
            if end > 1 {
                outline.trim(from: 0, to: end - 1).stroke(color, style: style)
            }
        }
    }
}

private struct AlasNSTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var monospaced: Bool
    var focusOnAppear: Bool
    var onSubmit: (() -> Void)?
    var isEnabled: Bool
    var disablesAutomaticTextSubstitutions: Bool
    var inputPolicy: AlasFieldInputPolicy?
    var onPaste: ((String) -> Bool)?

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
        field.disablesAutomaticTextSubstitutions = disablesAutomaticTextSubstitutions
        field.inputPolicy = inputPolicy
        field.onPaste = onPaste
        return field
    }

    func updateNSView(_ nsView: AlasNSTextFieldView, context: Context) {
        context.coordinator.parent = self
        nsView.isEnabled = isEnabled
        nsView.disablesAutomaticTextSubstitutions = disablesAutomaticTextSubstitutions
        nsView.inputPolicy = inputPolicy
        nsView.onPaste = onPaste
        if nsView.placeholderString != placeholder { nsView.placeholderString = placeholder }
        if context.coordinator.isEditing, let editor = nsView.currentEditor() as? NSTextView {
            let editingValue = context.coordinator.editingValue ?? editor.string
            if editingValue != text {
                // A genuine programmatic change (issue attach seeding the
                // name, the gg probe carrying the typed branch into the stack
                // field) reaches the field editor here. replaceEditorText
                // preserves a caret that was at the end of the old text —
                // append mode — instead of clamping it into the new length,
                // which parked the caret a character short of the end on a
                // growing replacement and made the next keystroke insert
                // mid-word.
                context.coordinator.replaceEditorText(editor, with: text)
                context.coordinator.editingValue = text
            }
        } else if nsView.stringValue != text {
            nsView.stringValue = text
        }
        // `nsView.window` can still be nil on the update pass that fires right after
        // `makeNSView` (the view hasn't been attached yet), which leaves
        // `nsView.focusOnAppear` unconsumed. This block then only gets a chance to run
        // later, on whatever update pass happens to land after the view is attached —
        // which, in the worst case, is the pass triggered by the user's first keystroke
        // (typing writes into `text`, which re-renders and calls `updateNSView`). If the
        // field is already being edited by then, re-acquiring first responder would reset
        // the field editor's selection to select-all and eat the next keystroke, so skip
        // the focus/selection dance entirely and just consume the flag.
        if focusOnAppear, nsView.focusOnAppear, nsView.window != nil {
            guard !context.coordinator.isEditing, nsView.currentEditor() == nil else {
                nsView.focusOnAppear = false
                return
            }
            nsView.focusOnAppear = false
            nsView.focusAndPlaceCaretAtEnd()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AlasNSTextField
        var isEditing = false
        var editingValue: String?
        init(_ parent: AlasNSTextField) {
            self.parent = parent
        }

        @objc func action(_ sender: NSTextField) {
            let value = sender.stringValue
            editingValue = value
            if value != parent.text {
                parent.text = value
            }
            parent.onSubmit?()
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
            guard let field = obj.object as? NSTextField else { return }
            editingValue = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            isEditing = true
            let editor = field.currentEditor() as? NSTextView
            if editor?.hasMarkedText() == true {
                return
            }
            let value = editor?.string ?? field.stringValue
            self.editingValue = value
            if value != parent.text {
                parent.text = value
            }
        }

        func controlTextDidEndEditing(_: Notification) {
            isEditing = false
            editingValue = nil
        }

        func replaceEditorText(_ editor: NSTextView, with text: String) {
            let selectedRange = editor.selectedRange()
            let oldLength = (editor.string as NSString).length
            editor.string = text
            let newLength = (text as NSString).length
            // A caret at the end of the old text means append mode: keep it at
            // the end of the new text rather than clamping into the stale
            // length, which parked the caret a character (or more) inside the
            // string and made the next keystroke insert mid-word.
            let location = selectedRange.location >= oldLength
                ? newLength
                : min(selectedRange.location, newLength)
            editor.setSelectedRange(NSRange(
                location: location,
                length: min(selectedRange.length, newLength - location)
            ))
        }
    }
}

class AlasNSTextFieldView: NSTextField {
    var focusOnAppear = false
    var disablesAutomaticTextSubstitutions: Bool = false {
        didSet { (cell as? AlasNSTextFieldCell)?.disablesAutomaticTextSubstitutions = disablesAutomaticTextSubstitutions }
    }
    var inputPolicy: AlasFieldInputPolicy? {
        didSet { (cell as? AlasNSTextFieldCell)?.inputPolicy = inputPolicy }
    }
    var onPaste: ((String) -> Bool)? {
        didSet { (cell as? AlasNSTextFieldCell)?.onPaste = onPaste }
    }

    /// Acquires first responder and moves the caret to the end of the
    /// current text, synchronously, in a single call. Acquiring first
    /// responder selects all of the field's text by default (AppKit's
    /// behavior), so the caret-to-end correction must happen in this same
    /// call rather than being deferred to a later run-loop turn: a deferred
    /// fix loses the race against the user's first keystroke, which lands
    /// while the whole string is still selected and gets replaced by it
    /// instead of appended to.
    @discardableResult
    func focusAndPlaceCaretAtEnd() -> Bool {
        guard let window else { return false }
        if window.firstResponder !== self, !window.makeFirstResponder(self) {
            return false
        }
        if let editor = currentEditor() as? NSTextView {
            editor.setSelectedRange(NSRange(location: (stringValue as NSString).length, length: 0))
        }
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureCell()
    }

    private func configureCell() {
        cell = AlasNSTextFieldCell(textCell: "")
        isEditable = true
        isSelectable = true
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
    }
}

/// Fields that disable automatic text substitutions get a private field
/// editor instead of AppKit's window-shared one: `setUpFieldEditorAttributes`
/// mutates the editor instance in place, and the shared editor is reused by
/// every plain `NSTextField` in the window, so disabling substitutions on it
/// would leak into unrelated fields the next time they're focused.
final class AlasNSTextFieldCell: NSTextFieldCell {
    var disablesAutomaticTextSubstitutions = false
    var inputPolicy: AlasFieldInputPolicy? {
        didSet {
            guard oldValue != inputPolicy else { return }
            isolatedFieldEditor.inputPolicy = inputPolicy
        }
    }
    var onPaste: ((String) -> Bool)? {
        didSet { isolatedFieldEditor.onPaste = onPaste }
    }

    private lazy var isolatedFieldEditor: AlasFieldEditor = {
        let editor = AlasFieldEditor()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        disablesAutomaticTextSubstitutions || inputPolicy != nil || onPaste != nil
            ? isolatedFieldEditor : super.fieldEditor(for: controlView)
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        guard let textView = editor as? NSTextView else { return editor }

        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.maximumNumberOfLines = 1
        if disablesAutomaticTextSubstitutions {
            textView.isAutomaticTextCompletionEnabled = false
            textView.inlinePredictionType = .no
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
        }
        return textView
    }
}

enum AlasFieldInputPolicy {
    case gitBranchName
}

/// Normalize only committed incoming text, before AppKit records the native
/// edit. Leave marked text, selection, deletion, and undo/redo to AppKit.
final class AlasFieldEditor: NSTextView {
    var inputPolicy: AlasFieldInputPolicy?
    var onPaste: ((String) -> Bool)?

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let text = pboard.string(forType: .string), onPaste?(text) == true {
            return true
        }
        guard inputPolicy == .gitBranchName, let text = pboard.string(forType: .string) else {
            return super.readSelection(from: pboard, type: type)
        }
        // NSTextView's paste path bypasses insertText. Route plain branch-name
        // paste through the same native insertion transaction as typing.
        insertText(text, replacementRange: selectedRange())
        return true
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard inputPolicy == .gitBranchName else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let text: String
        if let plain = insertString as? String {
            text = plain
        } else if let attributed = insertString as? NSAttributedString {
            text = attributed.string
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let normalized = GitNameValidator.normalizedBranchNameInput(text)
        // An entirely rejected insertion must not replace selected text.
        guard !normalized.isEmpty || text.isEmpty || hasMarkedText() else { return }
        super.insertText(normalized, replacementRange: replacementRange)
    }
}
