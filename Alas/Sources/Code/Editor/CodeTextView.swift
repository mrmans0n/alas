import AppKit

/// Editable `NSTextView` subclass. The coordinator wires hover and
/// Cmd-click callbacks; the storage is owned and managed by an
/// `EditorBuffer` outside this view. Editing is enabled but undo/redo,
/// dirty tracking, save, file-watch, and LSP `didChange` are all
/// orchestrated by the buffer + coordinator pair.
final class CodeTextView: NSTextView, FontSizeResponder {
    private static let pairedDelimiters: [Character: Character] = [
        "(": ")",
        "[": "]",
        "{": "}",
        "\"": "\"",
        "'": "'",
        "`": "`"
    ]

    private static let closingDelimiters: Set<Character> = [")", "]", "}"]

    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?
    var flagsChangedHandler: ((NSEvent) -> Void)?
    var mouseExitedHandler: (() -> Void)?
    var indentationMode: IndentationMode = .plain

    var autoPairDisabled: Bool = false

    /// Set by `CodeEditorCoordinator.attach`. Each closure mutates the shared
    /// `code.fontSize` config in response to the matching menu command.
    var increaseFontSizeHandler: (() -> Void)?
    var decreaseFontSizeHandler: (() -> Void)?
    var resetFontSizeHandler: (() -> Void)?

    @objc func increaseFontSize(_ sender: Any?) { increaseFontSizeHandler?() }
    @objc func decreaseFontSize(_ sender: Any?) { decreaseFontSizeHandler?() }
    @objc func resetFontSize(_ sender: Any?)    { resetFontSizeHandler?() }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        self.isEditable = true
        self.isSelectable = true
        self.allowsUndo = true
        self.isRichText = false
        self.usesFindBar = true
        self.isAutomaticQuoteSubstitutionEnabled = false
        self.isAutomaticDashSubstitutionEnabled = false
        self.isAutomaticTextReplacementEnabled = false
        self.isAutomaticSpellingCorrectionEnabled = false
        self.isContinuousSpellCheckingEnabled = false
        self.isGrammarCheckingEnabled = false
        self.smartInsertDeleteEnabled = false
        self.textContainerInset = NSSize(width: 12, height: 8)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        if autoPairDisabled {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard
            let text = Self.string(from: insertString),
            text.count == 1,
            let character = text.first
        else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        let range = effectiveReplacementRange(replacementRange)
        guard range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        // NEW: Closing delimiter dedent for whitespace-only lines
        if Self.closingDelimiters.contains(character),
           indentationMode == .bracketAware,
           let edit = IndentationHelper.closingDelimiterEdit(in: string, selectedRange: range, delimiter: character, mode: indentationMode) {
            super.insertText(edit.replacement, replacementRange: edit.replacementRange)
            setSelectedRange(NSRange(location: edit.replacementRange.location + edit.selectedLocationDelta, length: 0))
            return
        }

        if let closing = Self.pairedDelimiters[character] {
            if shouldInsertPair(opening: character, closing: closing, range: range) {
                insertPairedDelimiter(opening: character, closing: closing, replacementRange: range)
                return
            }
            if character == closing, range.length == 0, nextCharacter(at: range.location) == character {
                setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return
            }
        }

        if Self.closingDelimiters.contains(character), range.length == 0, nextCharacter(at: range.location) == character {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        }

        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else {
            super.insertNewline(sender)
            return
        }
        let range = selectedRange()
        if range.length > 0 {
            super.insertNewline(sender)
            return
        }
        if let edit = IndentationHelper.newlineEdit(in: string, selectedRange: range, mode: indentationMode) {
            super.insertText(edit.replacement, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + edit.selectedLocationDelta, length: 0))
        } else {
            super.insertNewline(sender)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        hoverHandler?(p)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            commandClickHandler?(p)
            return
        }
        super.mouseDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        flagsChangedHandler?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseExitedHandler?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
    }

    private static func string(from insertString: Any) -> String? {
        if let string = insertString as? String { return string }
        if let attributed = insertString as? NSAttributedString { return attributed.string }
        return nil
    }

    private func effectiveReplacementRange(_ replacementRange: NSRange) -> NSRange {
        replacementRange.location == NSNotFound ? selectedRange() : replacementRange
    }

    private func insertPairedDelimiter(opening: Character, closing: Character, replacementRange range: NSRange) {
        let current = string as NSString
        if opening == closing, range.length == 0, nextCharacter(at: range.location) == closing {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        }

        let selectedText = range.length > 0 ? current.substring(with: range) : ""
        let replacement = "\(opening)\(selectedText)\(closing)"
        super.insertText(replacement, replacementRange: range)

        if range.length > 0 {
            setSelectedRange(NSRange(location: range.location + 1, length: range.length))
        } else {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
        }
    }

    private func shouldInsertPair(opening: Character, closing: Character, range: NSRange) -> Bool {
        guard opening == closing, range.length == 0 else { return true }

        if isEscapedByBackslash(at: range.location) { return false }
        if isIdentifierLike(characterBefore: range.location) { return false }
        if isIdentifierLike(characterAfter: range.location) { return false }

        return true
    }

    private func nextCharacter(at location: Int) -> Character? {
        let nsString = string as NSString
        guard location < nsString.length else { return nil }
        return Character(nsString.substring(with: NSRange(location: location, length: 1)))
    }

    private func previousCharacter(before location: Int) -> Character? {
        guard location > 0 else { return nil }
        let nsString = string as NSString
        guard location <= nsString.length else { return nil }
        return Character(nsString.substring(with: NSRange(location: location - 1, length: 1)))
    }

    private func isIdentifierLike(characterBefore location: Int) -> Bool {
        guard let character = previousCharacter(before: location) else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    private func isIdentifierLike(characterAfter location: Int) -> Bool {
        guard let character = nextCharacter(at: location) else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    private func isEscapedByBackslash(at location: Int) -> Bool {
        var cursor = location
        var backslashCount = 0
        while previousCharacter(before: cursor) == "\\" {
            backslashCount += 1
            cursor -= 1
        }
        return backslashCount % 2 == 1
    }
}
