import AppKit

/// Editable `NSTextView` subclass. The coordinator wires hover and
/// Cmd-click callbacks; the storage is owned and managed by an
/// `EditorBuffer` outside this view. Editing is enabled but undo/redo,
/// dirty tracking, save, file-watch, and LSP `didChange` are all
/// orchestrated by the buffer + coordinator pair.
final class CodeTextView: NSTextView, FontSizeResponder {
    enum CompletionKeyAction: Equatable {
        case acceptTop
        case acceptSelected
        case moveSelection(Int)
        case dismiss
    }

    private static let indentationClosingDelimiters: Set<Character> = [")", "]", "}"]

    var hoverHandler: ((NSPoint) -> Void)?
    var commandClickHandler: ((NSPoint) -> Void)?
    var flagsChangedHandler: ((NSEvent) -> Void)?
    var mouseExitedHandler: (() -> Void)?
    var completionManualTriggerHandler: (() -> Void)?
    var completionChangeHandler: ((NSRange?) -> Void)?
    var completionSelectionChangeHandler: (() -> Void)?
    var escapeHandler: (() -> Bool)?
    var completionKeyHandler: ((CompletionKeyAction) -> Bool)?
    var indentationMode: IndentationMode = .plain

    var autoPairDisabled: Bool = false

    /// Text that the in-flight marked composition swallowed, kept so a dead-key
    /// delimiter can still wrap the selection the user had before pressing it.
    private var selectionReplacedByMarkedText: String?
    /// `NSTextView.unmarkText()` finalizes a composition by re-inserting the
    /// marked characters through `insertText`, so pairing has to stay suppressed
    /// while we replace them or the placeholder pairs with itself.
    private var isCommittingMarkedText = false

    /// Set by `CodeEditorCoordinator.attach`. Each closure mutates the shared
    /// `code.fontSize` config in response to the matching menu command.
    var increaseFontSizeHandler: (() -> Void)?
    var decreaseFontSizeHandler: (() -> Void)?
    var resetFontSizeHandler: (() -> Void)?

    private var multiCursorSelectedRanges: [NSValue]?
    private var possibleColumnSelectionDrag: ColumnSelectionDrag?
    private var suppressCompletionChangeNotifications = false
    private var suppressCompletionSelectionNotifications = false
    private var pendingCompletionEditRange: NSRange?
    private var isApplyingSelectionChange = false

    private struct ColumnSelectionDrag {
        let startPoint: NSPoint
        var hasExceededThreshold: Bool
    }

    private static let columnSelectionDragThreshold: CGFloat = 4

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
        let wasApplyingSelectionChange = isApplyingSelectionChange
        let shouldNotify = !wasApplyingSelectionChange
        isApplyingSelectionChange = true
        defer {
            isApplyingSelectionChange = wasApplyingSelectionChange
            if shouldNotify {
                notifyCompletionSelectionChanged()
            }
        }
        multiCursorSelectedRanges = nil
        super.setSelectedRange(charRange)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        let wasApplyingSelectionChange = isApplyingSelectionChange
        let shouldNotify = !wasApplyingSelectionChange
        isApplyingSelectionChange = true
        defer {
            isApplyingSelectionChange = wasApplyingSelectionChange
            if shouldNotify {
                notifyCompletionSelectionChanged()
            }
        }
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
            insertTextAfterTextEdit(edit.replacement, replacementRange: effectiveRange)
            let finalSelection = NSRange(
                location: edit.resultingSelection.location + delta,
                length: edit.resultingSelection.length
            )
            finalSelections.append(NSValue(range: finalSelection))
            delta += (edit.replacement as NSString).length - edit.originalRange.length
        }
        undoManager?.endUndoGrouping()
        setSelectedRangesAfterTextEdit(finalSelections, affinity: .downstream, stillSelecting: false)
    }

    private func editForCharacter(_ character: Character, at range: NSRange) -> MultiCursorEdit? {
        // Closing delimiter dedent
        if Self.indentationClosingDelimiters.contains(character),
           indentationMode == .bracketAware,
           let edit = IndentationHelper.closingDelimiterEdit(in: string, selectedRange: range, delimiter: character, mode: indentationMode) {
            return MultiCursorEdit(
                originalRange: edit.replacementRange,
                replacement: edit.replacement,
                resultingSelection: NSRange(location: edit.replacementRange.location + edit.selectedLocationDelta, length: 0)
            )
        }

        switch PairedDelimiterEditing.resolve(insertedText: String(character), in: string, selectedRange: range) {
        case let .wrap(opening, closing), let .insertPair(opening, closing):
            let current = string as NSString
            let selectedText = range.length > 0 ? current.substring(with: range) : ""
            return MultiCursorEdit(
                originalRange: range,
                replacement: "\(opening)\(selectedText)\(closing)",
                resultingSelection: NSRange(location: range.location + 1, length: range.length)
            )
        case .stepOver:
            return MultiCursorEdit(originalRange: range, replacement: "", resultingSelection: NSRange(location: range.location + 1, length: 0))
        case .native:
            return nil
        }
    }

    // MARK: - Text insertion overrides

    override func didChangeText() {
        super.didChangeText()
        notifyCompletionChanged()
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        let shouldChange = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if shouldChange { pendingCompletionEditRange = affectedCharRange }
        return shouldChange
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            let replaced = replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange
            let nsString = self.string as NSString
            selectionReplacedByMarkedText = replaced.length > 0 && NSMaxRange(replaced) <= nsString.length
                ? nsString.substring(with: replaced)
                : nil
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        selectionReplacedByMarkedText = nil
        super.unmarkText()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        guard !isCommittingMarkedText else {
            insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
            return
        }
        let replacedSelection = selectionReplacedByMarkedText
        selectionReplacedByMarkedText = nil
        guard let text = Self.string(from: insertString) else {
            insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
            return
        }

        if !autoPairDisabled, !hasMultipleSelections, hasMarkedText(),
           insertPairedDelimiterCommittingMarkedText(text, replacedSelection: replacedSelection) {
            return
        }

        if hasMultipleSelections && replacementRange.location == NSNotFound {
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
            insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
            return
        }
        guard text.count == 1, let character = text.first else {
            insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
            return
        }

        let range = effectiveReplacementRange(replacementRange)
        guard range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else {
            insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
            return
        }

        // NEW: Closing delimiter dedent for whitespace-only lines
        if Self.indentationClosingDelimiters.contains(character),
           indentationMode == .bracketAware,
           let edit = IndentationHelper.closingDelimiterEdit(in: string, selectedRange: range, delimiter: character, mode: indentationMode) {
            insertTextAfterTextEdit(edit.replacement, replacementRange: edit.replacementRange)
            setSelectedRangeAfterTextEdit(NSRange(location: edit.replacementRange.location + edit.selectedLocationDelta, length: 0))
            return
        }

        switch PairedDelimiterEditing.resolve(insertedText: text, in: string, selectedRange: range) {
        case let .wrap(opening, closing), let .insertPair(opening, closing):
            insertPairedDelimiter(opening: opening, closing: closing, replacementRange: range)
            return
        case .stepOver:
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        case .native:
            break
        }

        insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        super.deleteBackward(sender)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    override func deleteForward(_ sender: Any?) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        super.deleteForward(sender)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    override func insertNewline(_ sender: Any?) {
        guard isEditable else {
            super.insertNewline(sender)
            return
        }
        if routeCompletionKey(.acceptSelected) { return }

        if !hasMultipleSelections {
            insertNewlineSingleCursor(sender)
            return
        }

        let ranges = normalizedSelectedRanges()

        if ranges.contains(where: { $0.length > 0 }) {
            let edits = ranges.map {
                MultiCursorEdit(
                    originalRange: $0,
                    replacement: "\n",
                    resultingSelection: NSRange(location: $0.location + 1, length: 0)
                )
            }
            applyMultiCursorEdits(edits)
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

    override func complete(_ sender: Any?) {
        if let completionManualTriggerHandler {
            completionManualTriggerHandler()
        } else {
            super.complete(sender)
        }
    }

    override func insertTab(_ sender: Any?) {
        if routeCompletionKey(.acceptTop) { return }
        super.insertTab(sender)
    }

    override func moveUp(_ sender: Any?) {
        if routeCompletionKey(.moveSelection(-1)) { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if routeCompletionKey(.moveSelection(1)) { return }
        super.moveDown(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if escapeHandler?() == true { return }
        if routeCompletionKey(.dismiss) { return }
        super.cancelOperation(sender)
    }

    func completionAnchorRect() -> NSRect? {
        let selection = selectedRange()
        let nsLength = (string as NSString).length
        guard selection.location != NSNotFound, selection.location <= nsLength else { return nil }

        return localInsertionRect(at: selection.location)
    }

    private func localInsertionRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        return fallbackInsertionRect(at: location, layoutManager: layoutManager, textContainer: textContainer)
    }

    func applyCompletionEdits(_ edits: [CompletionTextEdit], finalSelection: NSRange) {
        let sorted = edits.sorted {
            $0.range.location < $1.range.location ||
                ($0.range.location == $1.range.location && $0.range.length < $1.range.length)
        }

        let wasSuppressingNotifications = suppressCompletionChangeNotifications
        suppressCompletionChangeNotifications = true

        undoManager?.beginUndoGrouping()
        for edit in sorted.reversed() {
            insertTextAfterTextEdit(edit.replacementText, replacementRange: edit.range)
        }
        undoManager?.endUndoGrouping()

        setSelectedRangeAfterTextEdit(finalSelection)
        suppressCompletionChangeNotifications = wasSuppressingNotifications
        if !wasSuppressingNotifications {
            notifyCompletionChanged()
        }
    }

    private func fallbackInsertionRect(at location: Int, layoutManager: NSLayoutManager, textContainer: NSTextContainer) -> NSRect {
        let nsString = string as NSString
        let lineHeight = font.map { layoutManager.defaultLineHeight(for: $0) } ?? 1
        let containerRect: NSRect

        if nsString.length == 0 {
            containerRect = NSRect(x: 0, y: 0, width: 1, height: lineHeight)
        } else if location == nsString.length, previousCharacter(before: location) == "\n" {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty {
                containerRect = NSRect(x: extra.minX, y: extra.minY, width: 1, height: max(extra.height, lineHeight))
            } else {
                let lineCount = nsString.components(separatedBy: "\n").count - 1
                containerRect = NSRect(x: 0, y: CGFloat(lineCount) * lineHeight, width: 1, height: lineHeight)
            }
        } else if location == nsString.length {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location - 1)
            let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            containerRect = NSRect(x: glyphRect.maxX, y: lineRect.minY, width: 1, height: lineRect.height)
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            containerRect = NSRect(
                x: layoutManager.location(forGlyphAt: glyphIndex).x,
                y: lineRect.minY,
                width: 1,
                height: lineRect.height
            )
        }

        return NSRect(
            x: textContainerOrigin.x + containerRect.minX,
            y: textContainerOrigin.y + containerRect.minY,
            width: max(containerRect.width, 1),
            height: max(containerRect.height, lineHeight)
        )
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
            insertTextAfterTextEdit(edit.replacement, replacementRange: range)
            setSelectedRangeAfterTextEdit(NSRange(location: range.location + edit.selectedLocationDelta, length: 0))
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
            possibleColumnSelectionDrag = ColumnSelectionDrag(startPoint: p, hasExceededThreshold: false)
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

        if event.modifierFlags.contains(.command) {
            let p = convert(event.locationInWindow, from: nil)
            commandClickHandler?(p)
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
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = possibleColumnSelectionDrag else {
            super.mouseDragged(with: event)
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        if !drag.hasExceededThreshold {
            let distance = hypot(p.x - drag.startPoint.x, p.y - drag.startPoint.y)
            guard distance >= Self.columnSelectionDragThreshold else { return }
            drag.hasExceededThreshold = true
            possibleColumnSelectionDrag = drag
        }

        let ranges = columnSelectionRanges(from: drag.startPoint, to: p)
        guard !ranges.isEmpty else { return }
        setNormalizedSelectedRanges(ranges)
    }

    override func mouseUp(with event: NSEvent) {
        let handledColumnDrag = possibleColumnSelectionDrag?.hasExceededThreshold == true
        possibleColumnSelectionDrag = nil
        if handledColumnDrag { return }
        super.mouseUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        flagsChangedHandler?(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        mouseExitedHandler?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, escapeHandler?() == true {
            return true
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCommandOnly = modifiers.contains(.command)
            && !modifiers.contains(.shift)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
        let isD = event.charactersIgnoringModifiers?.lowercased() == "d"
        if isCommandOnly, isD {
            addNextOccurrence()
            return true
        }
        return super.performKeyEquivalent(with: event)
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

    // MARK: - Selection helpers

    private func addNextOccurrence() {
        let ranges = normalizedSelectedRanges()
        guard !string.isEmpty else { return }

        let ns = string as NSString
        let activeRange: NSRange
        if let last = ranges.last, last.length > 0 {
            activeRange = last
        } else {
            let cursor = ranges.last?.location ?? selectedRange().location
            guard let word = wordRange(at: cursor) else { return }
            var updated = ranges
            if updated.isEmpty {
                updated = [word]
            } else {
                updated[updated.count - 1] = word
            }
            setNormalizedSelectedRanges(updated)
            scrollRangeToVisible(word)
            return
        }

        let needle = ns.substring(with: activeRange)
        guard !needle.isEmpty else { return }
        let searchStart = NSMaxRange(activeRange)
        guard let next = nextUnselectedOccurrence(of: needle, after: searchStart, selected: ranges) else { return }
        appendSelection(next)
        scrollRangeToVisible(next)
    }

    private func nextUnselectedOccurrence(of needle: String, after location: Int, selected: [NSRange]) -> NSRange? {
        let ns = string as NSString
        let length = ns.length
        guard location <= length else { return nil }

        var searchLocation = location
        var hasWrapped = false
        while true {
            let range = NSRange(location: searchLocation, length: length - searchLocation)
            let found = ns.range(of: needle, options: [], range: range)
            if found.location == NSNotFound {
                if !hasWrapped, location > 0 {
                    searchLocation = 0
                    hasWrapped = true
                    continue
                }
                return nil
            }
            if hasWrapped, found.location >= location { return nil }
            if !selected.contains(where: { NSEqualRanges($0, found) }) {
                return found
            }
            searchLocation = found.location + found.length
            if searchLocation > length { return nil }
        }
    }

    private func columnSelectionRanges(from startPoint: NSPoint, to endPoint: NSPoint) -> [NSRange] {
        guard let layoutManager, let textContainer else { return [] }
        let nsLength = (string as NSString).length
        guard nsLength > 0 else { return [] }

        layoutManager.ensureLayout(for: textContainer)

        let origin = textContainerOrigin
        let start = NSPoint(x: startPoint.x - origin.x, y: startPoint.y - origin.y)
        let end = NSPoint(x: endPoint.x - origin.x, y: endPoint.y - origin.y)
        let minX = min(start.x, end.x)
        let maxX = max(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxY = max(start.y, end.y)
        let selectionRect = NSRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var ranges: [NSRange] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            guard lineRect.intersects(selectionRect) || selectionRect.contains(NSPoint(x: minX, y: lineRect.midY)) else { return }

            let glyphCharRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            let lineCharRange = self.textContentRange(forLineCharacterRange: glyphCharRange)
            guard lineCharRange.location != NSNotFound, lineCharRange.location <= nsLength else { return }

            let y = lineRect.midY
            let startLocation = self.characterIndex(atContainerPoint: NSPoint(x: minX, y: y), constrainedTo: lineCharRange)
            let endLocation = self.characterIndex(atContainerPoint: NSPoint(x: maxX, y: y), constrainedTo: lineCharRange)
            let lower = min(startLocation, endLocation)
            let upper = max(startLocation, endLocation)
            ranges.append(NSRange(location: lower, length: upper - lower))
        }

        return ranges
    }

    private func characterIndex(atContainerPoint point: NSPoint, constrainedTo lineCharRange: NSRange) -> Int {
        guard let layoutManager, let textContainer else { return lineCharRange.location }
        let nsLength = (string as NSString).length
        let lineStart = min(max(lineCharRange.location, 0), nsLength)
        let lineEnd = min(max(NSMaxRange(lineCharRange), lineStart), nsLength)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return min(max(index, lineStart), lineEnd)
    }

    private func textContentRange(forLineCharacterRange lineCharRange: NSRange) -> NSRange {
        let nsString = string as NSString
        let nsLength = nsString.length
        let lineStart = min(max(lineCharRange.location, 0), nsLength)
        var lineEnd = min(max(NSMaxRange(lineCharRange), lineStart), nsLength)
        while lineEnd > lineStart {
            let trailing = nsString.substring(with: NSRange(location: lineEnd - 1, length: 1))
            guard trailing == "\n" || trailing == "\r" else { break }
            lineEnd -= 1
        }
        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }

    private func wordRange(at location: Int) -> NSRange? {
        let ns = string as NSString
        guard location >= 0, location <= ns.length else { return nil }
        if ns.length == 0 { return nil }
        let clamped = min(location, ns.length - 1)
        let char = ns.substring(with: NSRange(location: clamped, length: 1))
        guard char.rangeOfCharacter(from: .alphanumerics) != nil || char == "_" else { return nil }
        var start = clamped
        while start > 0 {
            let prev = ns.substring(with: NSRange(location: start - 1, length: 1))
            if prev.rangeOfCharacter(from: .alphanumerics) != nil || prev == "_" {
                start -= 1
            } else {
                break
            }
        }
        var end = clamped
        while end < ns.length - 1 {
            let next = ns.substring(with: NSRange(location: end + 1, length: 1))
            if next.rangeOfCharacter(from: .alphanumerics) != nil || next == "_" {
                end += 1
            } else {
                break
            }
        }
        let length = end - start + 1
        guard length > 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    // MARK: - Private helpers

    private func notifyCompletionChanged() {
        let editRange = pendingCompletionEditRange
        pendingCompletionEditRange = nil
        guard !suppressCompletionChangeNotifications else { return }
        completionChangeHandler?(editRange)
    }

    private func notifyCompletionSelectionChanged() {
        guard !suppressCompletionSelectionNotifications else { return }
        completionSelectionChangeHandler?()
    }

    private func setSelectedRangeAfterTextEdit(_ range: NSRange) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        setSelectedRange(range)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    private func setSelectedRangesAfterTextEdit(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    private func insertTextAfterTextEdit(_ insertString: Any, replacementRange: NSRange) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        super.insertText(insertString, replacementRange: replacementRange)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    private func routeCompletionKey(_ action: CompletionKeyAction) -> Bool {
        completionKeyHandler?(action) ?? false
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
        let selectedText = range.length > 0 ? current.substring(with: range) : ""
        let replacement = "\(opening)\(selectedText)\(closing)"
        insertTextAfterTextEdit(replacement, replacementRange: range)

        if range.length > 0 {
            setSelectedRangeAfterTextEdit(NSRange(location: range.location + 1, length: range.length))
        } else {
            setSelectedRangeAfterTextEdit(NSRange(location: range.location + 1, length: 0))
        }
    }

    /// Pairs a delimiter that arrived as a dead-key composition — layouts such as
    /// "U.S. International – PC" install `"`, `'` and `` ` `` as marked text and
    /// only commit the literal character on the next keystroke. Returns `false`
    /// for accented results and IME candidates so they insert natively.
    private func insertPairedDelimiterCommittingMarkedText(
        _ text: String,
        replacedSelection: String?
    ) -> Bool {
        let marked = markedRange()
        let nsString = string as NSString
        guard text.count == 1,
              marked.location != NSNotFound,
              marked.length > 0,
              NSMaxRange(marked) <= nsString.length,
              nsString.substring(with: marked) == text,
              let context = PairedDelimiterEditing.preCompositionContext(
                  text: string,
                  markedRange: marked,
                  replacedSelection: replacedSelection ?? ""
              )
        else { return false }

        switch PairedDelimiterEditing.resolve(
            insertedText: text,
            in: context.text,
            selectedRange: context.selectedRange
        ) {
        case let .wrap(opening, closing), let .insertPair(opening, closing):
            let wrapped = (context.text as NSString).substring(with: context.selectedRange)
            replaceMarkedText(with: "\(opening)\(wrapped)\(closing)", markedRange: marked)
            setSelectedRangeAfterTextEdit(NSRange(
                location: marked.location + 1,
                length: context.selectedRange.length
            ))
            return true

        case .stepOver:
            replaceMarkedText(with: "", markedRange: marked)
            setSelectedRangeAfterTextEdit(NSRange(location: marked.location + 1, length: 0))
            return true

        case .native:
            return false
        }
    }

    private func replaceMarkedText(with replacement: String, markedRange: NSRange) {
        isCommittingMarkedText = true
        defer { isCommittingMarkedText = false }
        unmarkText()
        insertTextAfterTextEdit(replacement, replacementRange: markedRange)
    }

    private func previousCharacter(before location: Int) -> Character? {
        guard location > 0 else { return nil }
        let nsString = string as NSString
        guard location <= nsString.length else { return nil }
        return Character(nsString.substring(with: NSRange(location: location - 1, length: 1)))
    }
}

extension CodeTextView {
    /// Returns the contiguous identifier-like range covering the character at
    /// `point`, or nil if the point is outside the text or not over an
    /// identifier character (`[A-Za-z0-9_]`). Used by hover and ⌘-underline.
    func symbolRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let containerPoint = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let nsString = storage.string as NSString
        guard charIndex < nsString.length else { return nil }
        let range = nsString.rangeOfWord(at: charIndex)
        return range.length == 0 ? nil : range
    }

    /// Returns the bounding rect (in view coordinates, including
    /// `textContainerInset`) of the first character of `range`. Used to anchor
    /// the hover popover under a token.
    func symbolAnchorRect(for range: NSRange) -> NSRect? {
        guard range.length > 0, let layoutManager, let textContainer else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        return rect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
    }
}

extension NSString {
    /// Returns the contiguous identifier-like range covering `index`, or an
    /// empty range if the character at `index` is not part of an identifier.
    func rangeOfWord(at index: Int) -> NSRange {
        guard index < length else { return NSRange(location: index, length: 0) }
        let isWordChar: (unichar) -> Bool = { c in
            (c >= 0x41 && c <= 0x5A) ||           // A-Z
            (c >= 0x61 && c <= 0x7A) ||           // a-z
            (c >= 0x30 && c <= 0x39) ||           // 0-9
             c == 0x5F                             // _
        }
        guard isWordChar(character(at: index)) else {
            return NSRange(location: index, length: 0)
        }
        var start = index
        while start > 0 && isWordChar(character(at: start - 1)) { start -= 1 }
        var end = index
        while end < length && isWordChar(character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
