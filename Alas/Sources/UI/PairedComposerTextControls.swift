import AppKit
import SwiftUI

class PairedDelimiterTextView: NSTextView {
    private var bypassesPairedDelimiterResolution = false
    private var appliesPairedDelimiterResolutionForKeyboardInput = false
    /// Text that the in-flight marked composition swallowed, kept so a dead-key
    /// delimiter can still wrap the selection the user had before pressing it.
    private var selectionReplacedByMarkedText: NSAttributedString?
    /// Opt-in triple-backtick handling. Off by default so surfaces that are
    /// not markdown — the shell startup script editors — keep plain pairing.
    var markdownFencesEnabled = false
    /// Set by the owning representable when fences are enabled; drives both
    /// text styling and the box drawn in `drawBackground(in:)`.
    var markdownCodeBlockStyle: MarkdownCodeBlockStyle?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isAutomaticQuoteSubstitutionEnabled = false
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            selectionReplacedByMarkedText = textStorage.flatMap { storage in
                replaced.length > 0 && Self.isValid(replaced, in: storage)
                    ? storage.attributedSubstring(from: replaced)
                    : nil
            }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let replacedSelection = selectionReplacedByMarkedText
        selectionReplacedByMarkedText = nil

        guard !bypassesPairedDelimiterResolution,
              appliesPairedDelimiterResolutionForKeyboardInput,
              let insertedText = Self.plainText(from: insertString)
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        if hasMarkedText() {
            commitMarkedText(
                insertString,
                insertedText: insertedText,
                replacementRange: replacementRange,
                replacedSelection: replacedSelection
            )
            return
        }

        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange

        if markdownFencesEnabled {
            switch MarkdownFenceEditing.resolve(
                insertedText: insertedText,
                in: string,
                selectedRange: range
            ) {
            case .openBlock:
                // The two backticks already in the storage plus this keystroke
                // become the whole block — and so does any closer that auto-
                // pairing parked after the caret, or it survives as a stray
                // backtick below the box.
                let trailing = MarkdownFenceEditing.trailingBacktickRun(at: range.location, in: string)
                insertFencedBlock(
                    replacing: NSRange(location: range.location - 2, length: 2 + trailing),
                    body: ""
                )
                return
            case .wrapSelection:
                let body = (string as NSString).substring(with: range)
                insertFencedBlock(
                    replacing: NSRange(location: range.location - 2, length: range.length + 4),
                    body: body
                )
                return
            case .none:
                // `MarkdownFenceEditing.resolve` returns `.none` here on
                // purpose — its contract is to fall through to plain pairing
                // for anything it doesn't recognize, including a backtick
                // that lands inside an existing block. But
                // `PairedDelimiterEditing` has no notion of fences, so the
                // closer it adds on the user's behalf can turn a run of
                // backticks into a fence line and re-cut the document's
                // blocks — see `swallowsFenceCollidingBacktick`. Swallow just
                // those keystrokes; everything else falls through untouched.
                if swallowsFenceCollidingBacktick(insertedText: insertedText, range: range) {
                    return
                }
            }
        }

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

    func fencedBlockRange(containing location: Int) -> FencedBlock? {
        guard markdownFencesEnabled else { return nil }
        return MarkdownFenceEditing.block(containing: location, in: string)
    }

    /// Whether a backtick landing at `range` — one `MarkdownFenceEditing`
    /// declined to handle, most commonly because it's inside an existing
    /// block — should be swallowed instead of falling through to
    /// `PairedDelimiterEditing`.
    ///
    /// `PairedDelimiterEditing` knows nothing about fences. It answers a
    /// backtick by putting *more* than the typed character into the storage:
    /// `.insertPair` writes two, `.wrap` writes one against each end of the
    /// selection. Those unrequested characters are what extend a backtick run
    /// far enough to read as a fence line, and a fence line appearing where
    /// the author didn't put one re-cuts the document — closing the enclosing
    /// block early, orphaning its real closer, or widening an opener past the
    /// closer that used to match it.
    ///
    /// So rather than restating the fence grammar here — line starts, indent
    /// tolerance, info strings, how wide a run must be to close its opener —
    /// per flank, in a form that has to be kept in step with the parser, this
    /// asks the parser: apply the exact edit `PairedDelimiterEditing` would
    /// apply, and refuse the keystroke when the block structure that comes
    /// back isn't the one already on screen. Every flank the edit touches is
    /// covered at once, because the comparison is over the whole document.
    ///
    /// Only the padded resolutions are inspected. `.stepOver` writes nothing,
    /// and `.native` writes exactly the character the user pressed — vetoing
    /// that would be a keystroke vanishing with no auto-pairing to blame,
    /// which is a worse outcome than the markdown it produces.
    private func swallowsFenceCollidingBacktick(insertedText: String, range: NSRange) -> Bool {
        guard insertedText == "`",
              let edited = pairedDelimiterPaddedResult(of: insertedText, at: range)
        else { return false }
        return Self.fenceStructure(of: edited) != Self.fenceStructure(of: string)
    }

    /// The document as `PairedDelimiterEditing` would leave it, or `nil` when
    /// the resolution adds nothing beyond the typed character and so cannot
    /// surprise the author with a fence.
    private func pairedDelimiterPaddedResult(of insertedText: String, at range: NSRange) -> String? {
        let ns = string as NSString
        guard Self.isValid(range, in: ns) else { return nil }

        switch PairedDelimiterEditing.resolve(
            insertedText: insertedText,
            in: string,
            selectedRange: range
        ) {
        case let .wrap(opening, closing):
            return ns.replacingCharacters(
                in: range,
                with: String(opening) + ns.substring(with: range) + String(closing)
            )
        case let .insertPair(opening, closing):
            return ns.replacingCharacters(in: range, with: String(opening) + String(closing))
        case .stepOver, .native:
            return nil
        }
    }

    /// Where every fenced block begins and ends, in line numbers.
    ///
    /// Line numbers rather than character offsets because the edits this
    /// guard weighs only ever insert backticks, never line terminators — and
    /// never between a CR and its LF, since AppKit hands over selections and
    /// carets on composed-character-sequence boundaries — so each line keeps
    /// its number across the edit and two fingerprints taken either side of
    /// it compare directly. Openers and closers pin the whole structure:
    /// everything else `blocks(in:)` reports (bodies, outer ranges, info
    /// strings) follows from which lines fence which.
    private static func fenceStructure(of text: String) -> [FencedBlockLines] {
        let ns = text as NSString
        var lineStarts: [Int] = []
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            guard lineRange.length > 0 else { break }
            lineStarts.append(lineRange.location)
            location = NSMaxRange(lineRange)
        }

        func lineNumber(of offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            var line = 0
            while low <= high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= offset {
                    line = middle
                    low = middle + 1
                } else {
                    high = middle - 1
                }
            }
            return line
        }

        return MarkdownFenceEditing.blocks(in: text).map { block in
            FencedBlockLines(
                open: lineNumber(of: block.openFenceRange.location),
                close: block.closeFenceRange.map { lineNumber(of: $0.location) }
            )
        }
    }

    /// One fenced block reduced to the lines its fences sit on, the unit
    /// `fenceStructure(of:)` compares. `close` is `nil` for a block that runs
    /// to the end of the document unclosed.
    private struct FencedBlockLines: Equatable {
        var open: Int
        var close: Int?
    }

    /// Replace `replaced` with a complete fenced block wrapping `body`, adding
    /// the newlines needed to keep both fences on lines of their own, and leave
    /// the selection on the body.
    private func insertFencedBlock(replacing replaced: NSRange, body: String) {
        guard let textStorage, Self.isValid(replaced, in: textStorage) else { return }
        let ns = string as NSString
        let needsLeadingNewline = replaced.location > 0
            && ns.character(at: replaced.location - 1) != 0x0A
        let suffixLocation = NSMaxRange(replaced)
        let needsTrailingNewline = suffixLocation < ns.length
            && ns.character(at: suffixLocation) != 0x0A
        let leading = needsLeadingNewline ? "\n" : ""
        let trailing = needsTrailingNewline ? "\n" : ""

        let replacement = NSAttributedString(
            string: leading + "```\n" + body + "\n```" + trailing,
            attributes: typingAttributes
        )

        undoManager?.beginUndoGrouping()
        performNativeTextInsertion {
            super.insertText(replacement, replacementRange: replaced)
        }
        undoManager?.endUndoGrouping()

        // "```\n" is four characters past the leading newline, if any.
        let bodyStart = replaced.location + (leading as NSString).length + 4
        setSelectedRange(NSRange(location: bodyStart, length: (body as NSString).length))
    }

    override func unmarkText() {
        selectionReplacedByMarkedText = nil
        super.unmarkText()
    }

    /// Handles the keystroke that commits a marked composition. Only a
    /// single-character commit that matches the marked text itself is treated as
    /// a dead-key delimiter — an accented result (`"` then `o` → `ö`) or a
    /// multi-character IME candidate falls through to native insertion.
    private func commitMarkedText(
        _ insertString: Any,
        insertedText: String,
        replacementRange: NSRange,
        replacedSelection: NSAttributedString?
    ) {
        let marked = markedRange()
        let nsString = string as NSString
        guard insertedText.count == 1,
              Self.isValid(marked, in: nsString),
              marked.length > 0,
              nsString.substring(with: marked) == insertedText,
              let context = PairedDelimiterEditing.preCompositionContext(
                  text: string,
                  markedRange: marked,
                  replacedSelection: replacedSelection?.string ?? ""
              )
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        switch PairedDelimiterEditing.resolve(
            insertedText: insertedText,
            in: context.text,
            selectedRange: context.selectedRange
        ) {
        case let .wrap(opening, closing):
            let replacement = NSMutableAttributedString(
                string: String(opening),
                attributes: typingAttributes
            )
            if let replacedSelection {
                replacement.append(replacedSelection)
            }
            replacement.append(NSAttributedString(
                string: String(closing),
                attributes: typingAttributes
            ))
            replaceMarkedText(with: replacement, markedRange: marked)
            setSelectedRange(NSRange(
                location: marked.location + 1,
                length: context.selectedRange.length
            ))

        case let .insertPair(opening, closing):
            replaceMarkedText(
                with: NSAttributedString(
                    string: String(opening) + String(closing),
                    attributes: typingAttributes
                ),
                markedRange: marked
            )
            setSelectedRange(NSRange(location: marked.location + 1, length: 0))

        case .stepOver:
            replaceMarkedText(
                with: NSAttributedString(string: "", attributes: typingAttributes),
                markedRange: marked
            )
            setSelectedRange(NSRange(location: marked.location + 1, length: 0))

        case .native:
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    /// `NSTextView.unmarkText()` finalizes the composition by re-inserting the
    /// marked characters through `insertText`, so the whole replacement has to
    /// run with pairing suppressed or the placeholder pairs with itself.
    private func replaceMarkedText(with replacement: NSAttributedString, markedRange: NSRange) {
        performNativeTextInsertion {
            unmarkText()
            super.insertText(replacement, replacementRange: markedRange)
        }
    }

    override func keyDown(with event: NSEvent) {
        performKeyboardTextInsertion {
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        performNativeTextInsertion {
            super.paste(sender)
        }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        performNativeTextInsertion {
            super.pasteAsPlainText(sender)
        }
    }

    override func pasteAsRichText(_ sender: Any?) {
        performNativeTextInsertion {
            super.pasteAsRichText(sender)
        }
    }

    func performKeyboardTextInsertion(_ insert: () -> Void) {
        appliesPairedDelimiterResolutionForKeyboardInput = true
        defer { appliesPairedDelimiterResolutionForKeyboardInput = false }
        insert()
    }

    func performNativeTextInsertion(_ insert: () -> Void) {
        bypassesPairedDelimiterResolution = true
        defer { bypassesPairedDelimiterResolution = false }
        insert()
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
        isValid(range, length: storage.length)
    }

    private static func isValid(_ range: NSRange, in string: NSString) -> Bool {
        isValid(range, length: string.length)
    }

    private static func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }
}

struct PairedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var textColor: NSColor
    var isEnabled: Bool
    var isBordered: Bool
    var isBezeled: Bool
    var drawsBackground: Bool
    var bezelStyle: NSTextField.BezelStyle?
    var focusRingType: NSFocusRingType
    var isFocused: Binding<Bool>?
    var onSubmit: (() -> Void)?

    init(
        text: Binding<String>,
        placeholder: String = "",
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        textColor: NSColor = .labelColor,
        isEnabled: Bool = true,
        isBordered: Bool = false,
        isBezeled: Bool = false,
        drawsBackground: Bool = false,
        bezelStyle: NSTextField.BezelStyle? = nil,
        focusRingType: NSFocusRingType = .default,
        isFocused: Binding<Bool>? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        _text = text
        self.placeholder = placeholder
        self.font = font
        self.textColor = textColor
        self.isEnabled = isEnabled
        self.isBordered = isBordered
        self.isBezeled = isBezeled
        self.drawsBackground = drawsBackground
        self.bezelStyle = bezelStyle
        self.focusRingType = focusRingType
        self.isFocused = isFocused
        self.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PairedTextFieldBackingView {
        let field = PairedTextFieldBackingView()
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
        let window = field.window
        let editor = field.currentEditor()
        field.onWindowChanged = nil
        field.delegate = nil
        field.target = nil
        if let editor, window?.firstResponder === editor {
            window?.makeFirstResponder(nil)
        }
    }

    private func applyConfiguration(to field: NSTextField, coordinator: Coordinator) {
        field.placeholderString = placeholder
        field.font = font
        field.textColor = textColor
        field.isBordered = isBordered
        field.isBezeled = isBezeled
        field.drawsBackground = drawsBackground
        field.focusRingType = focusRingType
        if let bezelStyle {
            field.bezelStyle = bezelStyle
        }
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
            field.currentEditor() as? NSTextView
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
    }
}

struct PairedTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var isEnabled: Bool
    var isFocused: Binding<Bool>?
    var textContainerInset: NSSize
    var placeholder: String?

    init(
        text: Binding<String>,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        textColor: NSColor = .labelColor,
        isEnabled: Bool = true,
        isFocused: Binding<Bool>? = nil,
        textContainerInset: NSSize = .zero,
        placeholder: String? = nil
    ) {
        _text = text
        self.font = font
        self.textColor = textColor
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.textContainerInset = textContainerInset
        self.placeholder = placeholder
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
        synchronizeLayout(of: textView, in: scrollView)
        applyConfiguration(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PairedDelimiterTextView else { return }
        synchronizeLayout(of: textView, in: scrollView)
        applyConfiguration(to: textView)
        context.coordinator.synchronizeFocus(for: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? PairedTextEditorBackingView else { return }
        let window = textView.window
        textView.onWindowChanged = nil
        textView.delegate = nil
        coordinator.textView = nil
        if window?.firstResponder === textView {
            window?.makeFirstResponder(nil)
        }
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
        textView.setAccessibilityPlaceholderValue(placeholder)
    }

    private func synchronizeLayout(of textView: PairedDelimiterTextView, in scrollView: NSScrollView) {
        let viewport = scrollView.contentView.bounds.size
        let width = max(viewport.width, scrollView.contentSize.width)
        let viewportHeight = max(viewport.height, scrollView.contentSize.height)
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        let contentHeight = Self.laidOutContentHeight(of: textView)
        let height = max(viewportHeight, contentHeight)
        textView.minSize = NSSize(width: 0, height: height)
        textView.frame.size = NSSize(
            width: width,
            height: height
        )
    }

    private static func laidOutContentHeight(of textView: PairedDelimiterTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return 0 }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return ceil(usedRect.height + textView.textContainerInset.height * 2)
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

    /// AppKit never routes a should-change-text callback to an `NSTextField`
    /// delegate, so delimiter pairing has to live in the field editor itself.
    override class var cellClass: AnyClass? {
        get { PairedTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}

final class PairedTextFieldCell: NSTextFieldCell {
    private lazy var pairedFieldEditor: PairedDelimiterTextView = {
        let editor = PairedDelimiterTextView()
        editor.isFieldEditor = true
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        pairedFieldEditor
    }
}

private final class PairedTextEditorBackingView: PairedDelimiterTextView {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}
