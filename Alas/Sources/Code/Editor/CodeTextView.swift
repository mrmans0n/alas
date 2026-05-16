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

    private var multiCursorSelectedRanges: [NSValue]?

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

    // MARK: - Multi-cursor editing

    override var selectedRanges: [NSValue] {
        get { multiCursorSelectedRanges ?? super.selectedRanges }
        set { setSelectedRanges(newValue, affinity: .downstream, stillSelecting: false) }
    }

    override func setSelectedRange(_ charRange: NSRange) {
        multiCursorSelectedRanges = nil
        super.setSelectedRange(charRange)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        let normalized = normalizedRanges(from: ranges)
        guard normalized.count > 1 else {
            multiCursorSelectedRanges = nil
            super.setSelectedRanges(normalized.map { NSValue(range: $0) }, affinity: affinity, stillSelecting: stillSelectingFlag)
            return
        }

        super.setSelectedRange(normalized[0])
        multiCursorSelectedRanges = normalized.map { NSValue(range: $0) }
    }

    @objc func splitSelectionIntoLines(_ sender: Any?) {
        guard isEditable else { return }
        splitSelectionIntoLineCursors()
    }

    private var hasMultipleSelections: Bool {
        selectedRanges.count > 1
    }

    private struct MultiCursorEdit {
        let originalRange: NSRange
        let replacement: String
        let resultingSelection: NSRange
    }

    private func normalizedRanges(from values: [NSValue]) -> [NSRange] {
        let nsLength = (string as NSString).length
        let ranges = values.map { $0.rangeValue }
        let valid = ranges.filter { $0.location != NSNotFound && NSMaxRange($0) <= nsLength }
        let sorted = valid.sorted {
            $0.location < $1.location || ($0.location == $1.location && $0.length < $1.length)
        }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, NSMaxRange(last) >= range.location {
                let merged = NSRange(
                    location: last.location,
                    length: max(NSMaxRange(last), NSMaxRange(range)) - last.location
                )
                result[result.count - 1] = merged
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func normalizedSelectedRanges() -> [NSRange] {
        normalizedRanges(from: selectedRanges)
    }

    private func setNormalizedSelectedRanges(_ ranges: [NSRange]) {
        let values = ranges.map { NSValue(range: $0) }
        setSelectedRanges(values, affinity: .downstream, stillSelecting: false)
    }

    func appendCursor(at location: Int) {
        var ranges = selectedRanges
        ranges.append(NSValue(range: NSRange(location: location, length: 0)))
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
    }

    func appendSelection(_ range: NSRange) {
        var ranges = selectedRanges
        ranges.append(NSValue(range: range))
        setSelectedRanges(ranges, affinity: .downstream, stillSelecting: false)
    }

    private func splitSelectionIntoLineCursors() {
        let current = selectedRange()
        guard current.length > 0 else { return }

        let ns = string as NSString
        var ranges: [NSRange] = []
        var lineStart = current.location
        let end = NSMaxRange(current)

        while lineStart < end {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let effectiveStart = max(lineRange.location, current.location)
            var effectiveEnd = min(NSMaxRange(lineRange), end)
            while effectiveEnd > effectiveStart {
                let trailing = ns.substring(with: NSRange(location: effectiveEnd - 1, length: 1))
                guard trailing == "\n" || trailing == "\r" else { break }
                effectiveEnd -= 1
            }
            let length = effectiveEnd - effectiveStart
            ranges.append(NSRange(location: effectiveStart, length: length))
            lineStart = NSMaxRange(lineRange)
        }

        if ranges.isEmpty {
            ranges.append(NSRange(location: current.location, length: 0))
        }

        setNormalizedSelectedRanges(ranges)
    }

    private func applyMultiCursorEdits(_ edits: [MultiCursorEdit]) {
        let sorted = edits.sorted { $0.originalRange.location < $1.originalRange.location }
        var delta = 0
        var finalSelections: [NSValue] = []

        undoManager?.beginUndoGrouping()
        for edit in sorted {
            let effectiveRange = NSRange(
                location: edit.originalRange.location + delta,
                length: edit.originalRange.length
            )
            super.insertText(edit.replacement, replacementRange: effectiveRange)
            let finalSelection = NSRange(
                location: edit.resultingSelection.location + delta,
                length: edit.resultingSelection.length
            )
            finalSelections.append(NSValue(range: finalSelection))
            delta += (edit.replacement as NSString).length - edit.originalRange.length
        }
        undoManager?.endUndoGrouping()
        setSelectedRanges(finalSelections, affinity: .downstream, stillSelecting: false)
    }

    private func editForCharacter(_ character: Character, at range: NSRange) -> MultiCursorEdit? {
        // Closing delimiter dedent
        if Self.closingDelimiters.contains(character),
           indentationMode == .bracketAware,
           let edit = IndentationHelper.closingDelimiterEdit(in: string, selectedRange: range, delimiter: character, mode: indentationMode) {
            return MultiCursorEdit(
                originalRange: edit.replacementRange,
                replacement: edit.replacement,
                resultingSelection: NSRange(location: edit.replacementRange.location + edit.selectedLocationDelta, length: 0)
            )
        }

        // Paired delimiter
        if let closing = Self.pairedDelimiters[character] {
            if shouldInsertPair(opening: character, closing: closing, range: range) {
                let current = string as NSString
                let selectedText = range.length > 0 ? current.substring(with: range) : ""
                let replacement = "\(character)\(selectedText)\(closing)"
                let resultingSelection: NSRange
                if range.length > 0 {
                    resultingSelection = NSRange(location: range.location + 1, length: range.length)
                } else {
                    resultingSelection = NSRange(location: range.location + 1, length: 0)
                }
                return MultiCursorEdit(originalRange: range, replacement: replacement, resultingSelection: resultingSelection)
            }
            if character == closing, range.length == 0, nextCharacter(at: range.location) == character {
                return MultiCursorEdit(originalRange: range, replacement: "", resultingSelection: NSRange(location: range.location + 1, length: 0))
            }
        }

        // Closing delimiter step-over (non-paired)
        if Self.closingDelimiters.contains(character), range.length == 0, nextCharacter(at: range.location) == character {
            return MultiCursorEdit(originalRange: range, replacement: "", resultingSelection: NSRange(location: range.location + 1, length: 0))
        }

        return nil
    }

    // MARK: - Text insertion overrides

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        guard let text = Self.string(from: insertString) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        if hasMultipleSelections {
            let ranges = normalizedSelectedRanges()
            var edits: [MultiCursorEdit] = []
            let character = text.count == 1 ? text.first : nil
            for range in ranges {
                if let character, !autoPairDisabled, let edit = editForCharacter(character, at: range) {
                    edits.append(edit)
                } else {
                    edits.append(MultiCursorEdit(
                        originalRange: range,
                        replacement: text,
                        resultingSelection: NSRange(location: range.location + (text as NSString).length, length: 0)
                    ))
                }
            }
            applyMultiCursorEdits(edits)
            return
        }

        if autoPairDisabled {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard text.count == 1, let character = text.first else {
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

        if !hasMultipleSelections {
            insertNewlineSingleCursor(sender)
            return
        }

        let ranges = normalizedSelectedRanges()

        // If any range has non-zero length, let AppKit handle it natively
        if ranges.contains(where: { $0.length > 0 }) {
            super.insertNewline(sender)
            return
        }

        // If cursors share a line, fall back to native to avoid conflicting edits
        if cursorsShareLine(ranges, in: string) {
            super.insertNewline(sender)
            return
        }

        var edits: [MultiCursorEdit] = []
        for range in ranges {
            if let edit = IndentationHelper.newlineEdit(in: string, selectedRange: range, mode: indentationMode) {
                edits.append(MultiCursorEdit(
                    originalRange: range,
                    replacement: edit.replacement,
                    resultingSelection: NSRange(location: range.location + edit.selectedLocationDelta, length: 0)
                ))
            } else {
                edits.append(MultiCursorEdit(
                    originalRange: range,
                    replacement: "\n",
                    resultingSelection: NSRange(location: range.location + 1, length: 0)
                ))
            }
        }

        applyMultiCursorEdits(edits)
    }

    private func indexAtPoint(_ point: NSPoint) -> Int {
        guard let lm = self.layoutManager,
              let container = self.textContainer else { return NSNotFound }
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        var fraction: CGFloat = 0
        return lm.characterIndex(
            for: containerPoint,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
    }

    private func insertNewlineSingleCursor(_ sender: Any?) {
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

    private func cursorsShareLine(_ ranges: [NSRange], in text: String) -> Bool {
        let nsString = text as NSString
        var lines = Set<Int>()
        for range in ranges {
            let lineRange = nsString.lineRange(for: NSRange(location: range.location, length: 0))
            if !lines.insert(lineRange.location).inserted {
                return true
            }
        }
        return false
    }

    // MARK: - Mouse / gesture handling

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        hoverHandler?(p)
    }

    override func mouseDown(with event: NSEvent) {
        let isOption = event.modifierFlags.contains(.option)
        let isShift = event.modifierFlags.contains(.shift)

        if isOption, !isShift {
            let p = convert(event.locationInWindow, from: nil)
            let charIndex = indexAtPoint(p)
            if charIndex != NSNotFound {
                appendCursor(at: charIndex)
            }
            return
        }

        if isOption, isShift {
            let p = convert(event.locationInWindow, from: nil)
            let charIndex = indexAtPoint(p)
            if charIndex != NSNotFound {
                let current = normalizedSelectedRanges()
                if let anchor = current.last {
                    let newRange: NSRange
                    if charIndex >= anchor.location {
                        newRange = NSRange(location: anchor.location, length: charIndex - anchor.location)
                    } else {
                        newRange = NSRange(location: charIndex, length: anchor.location - charIndex)
                    }
                    var updated = current
                    updated[updated.count - 1] = newRange
                    setNormalizedSelectedRanges(updated)
                } else {
                    appendCursor(at: charIndex)
                }
            }
            return
        }

        // Normal click clears multi-cursor
        if hasMultipleSelections {
            super.mouseDown(with: event)
            if selectedRanges.count > 1, let first = selectedRanges.first {
                setSelectedRanges([first], affinity: .downstream, stillSelecting: false)
            }
            return
        }

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

    // MARK: - Private helpers

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
