import AppKit

/// Editable `NSTextView` subclass. The coordinator wires hover and
/// Cmd-click callbacks; the storage is owned and managed by an
/// `EditorBuffer` outside this view. Editing is enabled but undo/redo,
/// dirty tracking, save, file-watch, and LSP `didChange` are all
/// orchestrated by the buffer + coordinator pair.
final class CodeTextView: NSTextView, FontSizeResponder {
    private(set) var displayAdapter: EditorDisplayAdapter?

    var sourceString: String { displayAdapter?.buffer.storage.string ?? string }
    var sourceSelectedRanges: [NSValue] {
        guard let displayAdapter else { return selectedRanges }
        var seen = Set<String>()
        var result: [NSValue] = []
        for selection in selectedRanges {
            guard let range = displayAdapter.sourceRange(forDisplay: selection.rangeValue) else { return [] }
            if seen.insert(NSStringFromRange(range)).inserted { result.append(NSValue(range: range)) }
        }
        return result
    }
    var sourceSelectedRange: NSRange { sourceSelectedRanges.first?.rangeValue ?? NSRange(location: NSNotFound, length: 0) }

    func setSourceSelectedRanges(_ ranges: [NSValue]) {
        guard let displayAdapter else { selectedRanges = ranges
        return }
        let mapped = ranges.compactMap { displayAdapter.displayRange(forSource: $0.rangeValue).map(NSValue.init(range:)) }
        selectedRanges = mapped.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : mapped
    }

    func restoreSourceSelections(_ ranges: [NSValue]) {
        let old = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        setSourceSelectedRanges(ranges)
        suppressCompletionSelectionNotifications = old
    }

    func bindDisplay(to buffer: EditorBuffer?) throws {
        let previousBuffer = displayAdapter?.buffer
        displayAdapter?.composition.commit()
        let sourceSelections = sourceSelectedRanges
        let scrollAnchor = displayAdapter?.captureScrollAnchor()
        displayAdapter?.detach()
        displayAdapter = nil
        sourceDrag = nil
        guard let buffer else { return }
        let adapter = try EditorDisplayAdapter(buffer: buffer, view: self)
        if let manager = layoutManager {
            manager.textStorage?.removeLayoutManager(manager)
            adapter.document.storage.addLayoutManager(manager)
        }
        displayAdapter = adapter
        if previousBuffer === buffer {
            restoreSourceSelections(sourceSelections)
            adapter.restoreScrollAnchor(scrollAnchor)
        }
    }

    @discardableResult
    func replaceSource(range: NSRange, with text: String) -> Bool {
        guard isEditable else { return false }
        if let displayAdapter {
            guard !displayAdapter.composition.isActive else { return false }
            let original = sourceString
            pendingCompletionEditRange = range
            guard displayAdapter.replaceSource(range, with: text) else { pendingCompletionEditRange = nil
            return false }
            if !EditorSourceText.exactlyEqual(original, sourceString) { didChangeText() } else { pendingCompletionEditRange = nil }
            return true
        }
        insertTextAfterTextEdit(text, replacementRange: range)
        return true
    }
    private weak var undoBuffer: EditorBuffer?
    private var suppressViewUndo = false
    override var undoManager: UndoManager? {
        if suppressViewUndo, undoBuffer != nil { return nil }
        return undoBuffer?.undoManager ?? super.undoManager
    }

    func bindUndo(to buffer: EditorBuffer?) {
        undoBuffer?.undoManager.breakTypingCoalescing()
        // Disable view-targeted AppKit inverses before exposing live history.
        // Toggling allowsUndo after installing the replacement can clear it.
        undoBuffer = nil
        if allowsUndo { allowsUndo = false }
        undoBuffer = buffer
    }
    enum CompletionKeyAction: Equatable {
        case acceptTop
        case acceptSelected
        case moveSelection(Int)
        case dismiss
    }

    private static let indentationClosingDelimiters: Set<Character> = [")", "]", "}"]

    var hoverHandler: ((NSPoint) -> Void)?
    var inlayHoverHandler: ((NSPoint?) -> Bool)?
    var inlayClickHandler: ((NSPoint) -> Bool)?
    var inlayAccessibilityActions: ((String) -> [NSAccessibilityCustomAction])?
    var commandClickHandler: ((NSPoint) -> Void)?
    var flagsChangedHandler: ((NSEvent) -> Void)?
    var mouseExitedHandler: (() -> Void)?
    var completionManualTriggerHandler: (() -> Void)?
    var completionChangeHandler: ((NSRange?) -> Void)?
    var completionSelectionChangeHandler: (() -> Void)?
    var signatureHelpManualTriggerHandler: (() -> Void)?
    var signatureHelpChangeHandler: (() -> Void)?
    var signatureHelpSelectionChangeHandler: (() -> Void)?
    var escapeHandler: (() -> Bool)?
    var completionKeyHandler: ((CompletionKeyAction) -> Bool)?
    private(set) var snippetSession: SnippetSession? {
        didSet { if snippetSession == nil { snippetChoiceWindow.hide() } }
    }
    private var snippetBufferSnapshot: String?
    let snippetChoiceWindow = CompletionWindowController()
    private var snippetChoiceRows: [CompletionPopupRow] = []
    private var snippetChoiceSelection = 0
    private var snippetTheme = Theme.fallback
    var indentationMode: IndentationMode = .plain
    var warningToolTipProvider: ((NSPoint) -> String?)? { didSet { refreshWarningToolTip() } }
    private var warningToolTipTag: NSView.ToolTipTag?

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
    var editorCommandRouter: EditorCommandRouter?
    private var commandTargetRange: NSRange?
    private var commandStatusPopover: NSPopover?

    private var multiCursorSelectedRanges: [NSValue]?
    private var possibleColumnSelectionDrag: ColumnSelectionDrag?
    private var suppressCompletionChangeNotifications = false
    private var suppressCompletionSelectionNotifications = false
    private var pendingCompletionEditRange: NSRange?
    private var isApplyingSelectionChange = false
    private var sourceCommandView: NSTextView?
    private struct SourceDrag {
        let buffer: EditorBuffer
        let revision: Int
        let ranges: [NSRange]
        let contents: [String]
    }
    private var sourceDrag: SourceDrag?
    private var sourceDragHandled = false

    private struct ColumnSelectionDrag {
        let startPoint: NSPoint
        var hasExceededThreshold: Bool
    }

    private static let columnSelectionDragThreshold: CGFloat = 4

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    @objc func increaseFontSize(_ sender: Any?) { increaseFontSizeHandler?() }
    @objc func decreaseFontSize(_ sender: Any?) { decreaseFontSizeHandler?() }
    @objc func resetFontSize(_ sender: Any?)    { resetFontSizeHandler?() }
    @objc func goToDefinition(_ sender: Any?) { invokeEditorCommand(.definition) }
    @objc func goToTypeDefinition(_ sender: Any?) { invokeEditorCommand(.typeDefinition) }
    @objc func goToImplementation(_ sender: Any?) { invokeEditorCommand(.implementation) }
    @objc func findReferences(_ sender: Any?) { invokeEditorCommand(.references) }
    @objc func renameSymbol(_ sender: Any?) { invokeEditorCommand(.rename) }
    @objc func showCodeActions(_ sender: Any?) { invokeEditorCommand(.codeActions) }
    @objc func formatSelection(_ sender: Any?) { invokeEditorCommand(.formatSelection) }
    @objc func formatDocument(_ sender: Any?) { invokeEditorCommand(.formatDocument) }
    @objc func showHover(_ sender: Any?) { invokeEditorCommand(.hover) }
    @objc func showSignatureHelp(_ sender: Any?) { invokeEditorCommand(.signatureHelp) }
    @objc func goBack(_ sender: Any?) { invokeEditorCommand(.back) }
    @objc func goForward(_ sender: Any?) { invokeEditorCommand(.forward) }
    @objc func nextProblem(_ sender: Any?) { invokeEditorCommand(.nextProblem) }
    @objc func previousProblem(_ sender: Any?) { invokeEditorCommand(.previousProblem) }
    @objc func toggleInlayHints(_ sender: Any?) { invokeEditorCommand(.toggleInlayHints) }

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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshWarningToolTip()
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder, let editorCommandRouter {
            EditorCommandAvailability.shared.activate(editorCommandRouter)
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { displayAdapter?.composition.commit() }
        if resignedFirstResponder, let editorCommandRouter {
            EditorCommandAvailability.shared.deactivate(editorCommandRouter)
        }
        return resignedFirstResponder
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let nativeMenu = super.menu(for: event) ?? NSMenu()
        guard let editorCommandRouter else { return nativeMenu }

        let point = convert(event.locationInWindow, from: nil)
        let offset = utf16Offset(at: point) ?? sourceSelectedRange.location
        commandTargetRange = EditorCommandRouter.targetRange(
            clickOffset: offset,
            selection: sourceSelectedRange
        )

        let commands = editorCommandRouter.availableCommands()
        guard !commands.isEmpty else {
            if !editorCommandRouter.serverIsReady,
               EditorCommandID.allCases.contains(where: editorCommandRouter.isSupported) {
                nativeMenu.addItem(.separator())
                let unavailable = NSMenuItem(title: "Language server unavailable", action: nil, keyEquivalent: "")
                unavailable.isEnabled = false
                nativeMenu.addItem(unavailable)
            }
            return nativeMenu
        }

        nativeMenu.addItem(.separator())
        appendCommandGroup([.definition, .typeDefinition, .implementation, .references], to: nativeMenu, available: commands)
        appendCommandGroup([.rename, .codeActions, .formatSelection, .formatDocument], to: nativeMenu, available: commands)
        appendCommandGroup([.hover, .signatureHelp, .nextProblem, .previousProblem], to: nativeMenu, available: commands)
        return nativeMenu
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let command = Self.editorCommand(for: item.action) else {
            return super.validateUserInterfaceItem(item)
        }
        return editorCommandRouter?.availableCommands().contains(command) == true
    }

    private func appendCommandGroup(_ commands: [EditorCommandID], to menu: NSMenu, available: [EditorCommandID]) {
        let group = commands.filter { available.contains($0) }
        guard !group.isEmpty else { return }
        if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
        for command in group {
            let item = NSMenuItem(
                title: Self.title(for: command),
                action: Self.selector(for: command),
                keyEquivalent: Self.keyEquivalent(for: command)
            )
            item.keyEquivalentModifierMask = Self.keyEquivalentModifiers(for: command)
            item.target = self
            menu.addItem(item)
        }
    }

    private func invokeEditorCommand(_ command: EditorCommandID) {
        let range = commandTargetRange ?? sourceSelectedRange
        editorCommandRouter?.invoke(command, range: range)
        commandTargetRange = nil
    }

    func triggerCommandClick(atUTF16Offset offset: Int) {
        guard let position = TextEditCoordinates.lspPosition(utf16Offset: offset, in: sourceString),
              let rect = firstRect(for: position)
        else { return }
        commandClickHandler?(NSPoint(x: rect.midX, y: rect.midY))
    }

    func triggerHover(atUTF16Offset offset: Int) {
        guard let position = TextEditCoordinates.lspPosition(utf16Offset: offset, in: sourceString),
              let rect = firstRect(for: position)
        else { return }
        hoverHandler?(NSPoint(x: rect.midX, y: rect.midY))
    }

    func showCommandStatus(_ message: String) {
        commandStatusPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSTextField(labelWithString: message)
        popover.contentViewController?.view.frame = NSRect(x: 0, y: 0, width: 220, height: 28)
        let range = commandTargetRange ?? sourceSelectedRange
        let rect = (TextEditCoordinates.lspPosition(utf16Offset: range.location, in: sourceString)).flatMap(firstRect(for:))
            ?? NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        commandStatusPopover = popover
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak popover] in popover?.close() }
    }

    private static func editorCommand(for selector: Selector?) -> EditorCommandID? {
        guard let selector else { return nil }
        return EditorCommandID.allCases.first { Self.selector(for: $0) == selector }
    }

    static func selector(for command: EditorCommandID) -> Selector {
        switch command {
        case .definition: #selector(goToDefinition(_:))
        case .typeDefinition: #selector(goToTypeDefinition(_:))
        case .implementation: #selector(goToImplementation(_:))
        case .references: #selector(findReferences(_:))
        case .rename: #selector(renameSymbol(_:))
        case .codeActions: #selector(showCodeActions(_:))
        case .formatSelection: #selector(formatSelection(_:))
        case .formatDocument: #selector(formatDocument(_:))
        case .hover: #selector(showHover(_:))
        case .signatureHelp: #selector(showSignatureHelp(_:))
        case .back: #selector(goBack(_:))
        case .forward: #selector(goForward(_:))
        case .nextProblem: #selector(nextProblem(_:))
        case .previousProblem: #selector(previousProblem(_:))
        case .toggleInlayHints: #selector(toggleInlayHints(_:))
        }
    }

    private static func title(for command: EditorCommandID) -> String {
        switch command {
        case .definition: "Go to Definition"
        case .typeDefinition: "Go to Type Definition"
        case .implementation: "Go to Implementation"
        case .references: "Find References"
        case .rename: "Rename Symbol"
        case .codeActions: "Code Actions"
        case .formatSelection: "Format Selection"
        case .formatDocument: "Format Document"
        case .hover: "Show Hover"
        case .signatureHelp: "Show Signature Help"
        case .back: "Back"
        case .forward: "Forward"
        case .nextProblem: "Next Problem"
        case .previousProblem: "Previous Problem"
        case .toggleInlayHints: "Toggle Inlay Hints"
        }
    }

    private static func keyEquivalent(for command: EditorCommandID) -> String {
        switch command {
        case .definition: "\u{F70F}"
        case .references: "\u{F70F}"
        case .rename: "\u{F705}"
        case .codeActions: "\r"
        default: ""
        }
    }

    private static func keyEquivalentModifiers(for command: EditorCommandID) -> NSEvent.ModifierFlags {
        switch command {
        case .references: [.shift]
        case .codeActions: [.option]
        default: []
        }
    }

    private func refreshWarningToolTip() {
        if let warningToolTipTag { removeToolTip(warningToolTipTag) }
        warningToolTipTag = warningToolTipProvider == nil ? nil : addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        warningToolTipProvider?(point) ?? ""
    }

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
        sourceSelectedRanges.map(\.rangeValue)
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
        let current = sourceSelectedRange
        guard current.length > 0 else { return }

        let ns = sourceString as NSString
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

        setSourceSelectedRanges(ranges.map(NSValue.init(range:)))
    }

    private func applyMultiCursorEdits(_ edits: [MultiCursorEdit]) {
        guard isEditable, !edits.isEmpty else { return }
        if let adapter = displayAdapter, !adapter.buffer.acceptsSourceInput || adapter.composition.isActive || sourceSelectedRanges.isEmpty { return }
        let sorted = edits.sorted { $0.originalRange.location < $1.originalRange.location }
        var delta = 0
        var finalSelections: [NSValue] = []

        undoManager?.beginUndoGrouping()
        for edit in sorted {
            let effectiveRange = NSRange(
                location: edit.originalRange.location + delta,
                length: edit.originalRange.length
            )
            if effectiveRange.length > 0 || !edit.replacement.isEmpty {
                insertTextAfterTextEdit(edit.replacement, replacementRange: effectiveRange)
            }
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
           let edit = IndentationHelper.closingDelimiterEdit(in: sourceString, selectedRange: range, delimiter: character, mode: indentationMode) {
            return MultiCursorEdit(
                originalRange: edit.replacementRange,
                replacement: edit.replacement,
                resultingSelection: NSRange(location: edit.replacementRange.location + edit.selectedLocationDelta, length: 0)
            )
        }

        switch PairedDelimiterEditing.resolve(insertedText: String(character), in: sourceString, selectedRange: range) {
        case let .wrap(opening, closing), let .insertPair(opening, closing):
            let current = sourceString as NSString
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

    private func deleteSourceCharacter(backwards: Bool) {
        guard isEditable, let adapter = displayAdapter else { return }
        if adapter.composition.isActive { adapter.composition.commit() }
        let native = selectedRanges.map(\.rangeValue)
        let source = sourceSelectedRanges.map(\.rangeValue)
        var edits: [MultiCursorEdit] = []
        let text = sourceString as NSString
        for (index, selection) in source.enumerated() {
            var range = selection
            // An attachment selection is intentionally empty in source.
            if range.length == 0, index < native.count, native[index].length > 0 { continue }
            if range.length == 0 {
                if backwards, range.location > 0 { range = text.rangeOfComposedCharacterSequence(at: range.location - 1) }
                else if !backwards, range.location < text.length { range = text.rangeOfComposedCharacterSequence(at: range.location) }
                else { continue }
            }
            if source.count == 1, snippetSession != nil, replaceSnippet(range, with: "") { return }
            edits.append(MultiCursorEdit(originalRange: range, replacement: "", resultingSelection: NSRange(location: range.location, length: 0)))
        }
        if edits.count == 1, let edit = edits.first {
            insertTextAfterTextEdit("", replacementRange: edit.originalRange)
        } else if !edits.isEmpty { applyMultiCursorEdits(edits) }
    }

    /// AppKit computes uncommon text-derived commands against source only. Reuse
    /// this view, and never use it for ordinary typing or caret movement.
    private func performSourceCommand(_ command: (NSTextView) -> Void) {
        guard isEditable, let adapter = displayAdapter, adapter.buffer.acceptsSourceInput else { return }
        if adapter.composition.isActive { adapter.composition.commit() }
        let ranges = sourceSelectedRanges
        guard !ranges.isEmpty else { return }
        if selectedRanges.contains(where: { $0.rangeValue.length > 0 }), ranges.allSatisfy({ $0.rangeValue.length == 0 }) { return }
        let scratch = sourceCommandView ?? NSTextView(frame: frame)
        sourceCommandView = scratch
        scratch.isRichText = false
        scratch.allowsUndo = false
        let original = sourceString
        scratch.string = original
        scratch.selectedRanges = ranges
        command(scratch)
        let difference = EditorSourceDifference(from: original, to: scratch.string)
        guard difference.range.length > 0 || !difference.replacement.isEmpty else { return }
        if replaceSource(range: difference.range, with: difference.replacement) {
            setSelectedRangesAfterTextEdit(scratch.selectedRanges, affinity: .downstream, stillSelecting: false)
        }
    }

    override func deleteWordBackward(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteWordBackward(sender) } } else { super.deleteWordBackward(sender) }
    }
    override func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteBackwardByDecomposingPreviousCharacter(sender) } }
        else { super.deleteBackwardByDecomposingPreviousCharacter(sender) }
    }
    override func deleteWordForward(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteWordForward(sender) } } else { super.deleteWordForward(sender) }
    }
    override func deleteToBeginningOfLine(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteToBeginningOfLine(sender) } } else { super.deleteToBeginningOfLine(sender) }
    }
    override func deleteToEndOfLine(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteToEndOfLine(sender) } } else { super.deleteToEndOfLine(sender) }
    }
    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteToBeginningOfParagraph(sender) } } else { super.deleteToBeginningOfParagraph(sender) }
    }
    override func deleteToEndOfParagraph(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.deleteToEndOfParagraph(sender) } } else { super.deleteToEndOfParagraph(sender) }
    }
    override func transpose(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.transpose(sender) } } else { super.transpose(sender) }
    }
    override func transposeWords(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.transposeWords(sender) } } else { super.transposeWords(sender) }
    }
    override func uppercaseWord(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.uppercaseWord(sender) } } else { super.uppercaseWord(sender) }
    }
    override func lowercaseWord(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.lowercaseWord(sender) } } else { super.lowercaseWord(sender) }
    }
    override func capitalizeWord(_ sender: Any?) {
        if displayAdapter != nil { performSourceCommand { $0.capitalizeWord(sender) } } else { super.capitalizeWord(sender) }
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard let adapter = displayAdapter else { return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings) }
        guard isEditable, adapter.buffer.acceptsSourceInput, !adapter.composition.isActive else { return false }
        guard let replacementStrings, affectedRanges.count == replacementStrings.count, !affectedRanges.isEmpty else { return false }
        let ranges = affectedRanges.compactMap { adapter.sourceRange(forDisplay: $0.rangeValue) }
        guard ranges.count == affectedRanges.count else { return false }
        let edits = zip(ranges, replacementStrings).map { CompletionTextEdit(range: $0.0, replacementText: $0.1) }
        let sorted = ranges.sorted { $0.location < $1.location }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ NSMaxRange($0.0) <= $0.1.location }) else { return false }
        applyCompletionEdits(edits, finalSelection: NSRange(location: ranges[0].location + replacementStrings[0].utf16.count, length: 0))
        return false
    }

    override func performValidatedReplacement(in range: NSRange, with attributedString: NSAttributedString) -> Bool {
        guard let adapter = displayAdapter else { return super.performValidatedReplacement(in: range, with: attributedString) }
        guard let source = adapter.sourceRange(forDisplay: range) else { return false }
        return replaceSource(range: source, with: attributedString.string)
    }

    override func replaceCharacters(in range: NSRange, with string: String) {
        guard let adapter = displayAdapter else { super.replaceCharacters(in: range, with: string)
        return }
        if let source = adapter.sourceRange(forDisplay: range) { _ = replaceSource(range: source, with: string) }
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard displayAdapter != nil else { return super.writeSelection(to: pboard, type: type) }
        guard type == .string else { return false }
        let source = sourceString as NSString
        let parts = sourceSelectedRanges.map(\.rangeValue).filter { $0.length > 0 }.map { source.substring(with: $0) }
        return !parts.isEmpty && pboard.setString(parts.joined(separator: "\n"), forType: .string)
    }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard displayAdapter != nil else { return super.writeSelection(to: pboard, types: types) }
        guard sourceSelectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return false }
        pboard.declareTypes([.string], owner: nil)
        return writeSelection(to: pboard, type: .string)
    }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard displayAdapter != nil else { return super.readSelection(from: pboard, type: type) }
        guard isEditable, displayAdapter?.buffer.acceptsSourceInput == true,
              let text = pboard.string(forType: .string), displayAdapter?.composition.isActive != true else { return false }
        let edits = sourceSelectedRanges.map { MultiCursorEdit(originalRange: $0.rangeValue, replacement: text, resultingSelection: NSRange(location: $0.rangeValue.location + text.utf16.count, length: 0)) }
        guard !edits.isEmpty else { return false }
        applyMultiCursorEdits(edits)
        return true
    }
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        displayAdapter == nil ? super.readSelection(from: pboard) : readSelection(from: pboard, type: .string)
    }
    override func copy(_ sender: Any?) {
        if displayAdapter != nil { _ = writeSelection(to: .general, types: [.string]) } else { super.copy(sender) }
    }
    override func cut(_ sender: Any?) {
        guard displayAdapter != nil else { super.cut(sender)
        return }
        guard isEditable, displayAdapter?.buffer.acceptsSourceInput == true,
              displayAdapter?.composition.isActive != true, writeSelection(to: .general, types: [.string]) else { return }
        // Collapsed secondary selections survive cut, but never expand into
        // backward deletions. The batch shifts their resulting source carets.
        applyMultiCursorEdits(sourceSelectedRanges.map {
            MultiCursorEdit(originalRange: $0.rangeValue, replacement: "", resultingSelection: NSRange(location: $0.rangeValue.location, length: 0))
        })
    }
    override func paste(_ sender: Any?) {
        if displayAdapter != nil { _ = readSelection(from: .general) } else { super.paste(sender) }
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if displayAdapter != nil { _ = readSelection(from: .general) } else { super.pasteAsPlainText(sender) }
    }
    override func pasteAsRichText(_ sender: Any?) {
        if displayAdapter != nil { _ = readSelection(from: .general) } else { super.pasteAsRichText(sender) }
    }

    @discardableResult
    func moveSourceSelection(to destination: Int) -> Bool {
        guard isEditable, displayAdapter?.composition.isActive != true, destination >= 0, destination <= sourceString.utf16.count else { return false }
        let ranges = sourceSelectedRanges.map(\.rangeValue).filter { $0.length > 0 }.sorted { $0.location < $1.location }
        guard !ranges.isEmpty, !ranges.contains(where: { destination >= $0.location && destination <= NSMaxRange($0) }) else { return false }
        let original = sourceString
        let text = NSMutableString(string: original)
        let payload = ranges.map { text.substring(with: $0) }.joined(separator: "\n")
        let insertion = destination - ranges.filter { NSMaxRange($0) < destination }.reduce(0) { $0 + $1.length }
        for range in ranges.reversed() { text.deleteCharacters(in: range) }
        text.insert(payload, at: insertion)
        let difference = EditorSourceDifference(from: original, to: text as String)
        guard replaceSource(range: difference.range, with: difference.replacement) else { return false }
        setSelectedRangeAfterTextEdit(NSRange(location: insertion, length: payload.utf16.count))
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let adapter = displayAdapter else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        guard let destination = adapter.sourceRange(forDisplay: NSRange(location: characterIndexForInsertion(at: point), length: 0))?.location else { return false }
        if let source = sender.draggingSource as? CodeTextView, source.displayAdapter?.buffer === adapter.buffer {
            guard source.sourceDragIsCurrent else { return false }
            let copying = NSApp.currentEvent?.modifierFlags.contains(.option) == true || !sender.draggingSourceOperationMask.contains(.move)
            if !copying {
                if let drag = source.sourceDrag { source.restoreSourceSelections(drag.ranges.map(NSValue.init(range:))) }
                let moved = source.moveSourceSelection(to: destination)
                source.sourceDragHandled = true
                if moved { restoreSourceSelections(source.sourceSelectedRanges) }
                return moved
            }
        }
        guard let text = sender.draggingPasteboard.string(forType: .string) else { return false }
        return replaceSource(range: NSRange(location: destination, length: 0), with: text)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            if displayAdapter == nil { super.draggingSession(session, endedAt: screenPoint, operation: operation) }
            else { finishSourceDrag(operation: operation) }
        }
    }

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        MainActor.assumeIsolated {
            // NSTextView does not implement the optional willBegin callback.
            if displayAdapter != nil { beginSourceDrag() }
        }
    }

    func beginSourceDrag() {
        sourceDragHandled = false
        guard let adapter = displayAdapter, !adapter.composition.isActive else { sourceDrag = nil
        return }
        let ranges = sourceSelectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        let text = sourceString as NSString
        sourceDrag = SourceDrag(buffer: adapter.buffer, revision: adapter.buffer.editGeneration, ranges: ranges,
                                contents: ranges.map { text.substring(with: $0) })
    }

    private var sourceDragIsCurrent: Bool {
        guard let drag = sourceDrag else { return true }
        guard displayAdapter?.buffer === drag.buffer, drag.buffer.editGeneration == drag.revision else { return false }
        let text = drag.buffer.storage.string as NSString
        return zip(drag.ranges, drag.contents).allSatisfy { NSMaxRange($0.0) <= text.length && EditorSourceText.exactlyEqual(text.substring(with: $0.0), $0.1) }
    }

    func finishSourceDrag(operation: NSDragOperation) {
        defer { sourceDrag = nil
        sourceDragHandled = false }
        guard let drag = sourceDrag, operation.contains(.move), !sourceDragHandled, sourceDragIsCurrent,
              isEditable, displayAdapter?.buffer.acceptsSourceInput == true, displayAdapter?.composition.isActive != true else { return }
        restoreSourceSelections(drag.ranges.map(NSValue.init(range:)))
        let edits = drag.ranges.map { MultiCursorEdit(originalRange: $0, replacement: "", resultingSelection: NSRange(location: $0.location, length: 0)) }
        if !edits.isEmpty { applyMultiCursorEdits(edits) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !hasMarkedText(), event.keyCode == 48, modifiers.isEmpty || modifiers == [.shift],
           advanceSnippet(backwards: modifiers == [.shift]) { return }
        if !hasMarkedText(), modifiers.isEmpty {
            switch event.keyCode {
            case 36, 76, 48: // Return, keypad Enter, Tab
                if routeCompletionKey(.acceptSelected) { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        if !suppressCompletionChangeNotifications { snippetSession = nil }
        notifyCompletionChanged()
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let displayAdapter {
            guard let replacementString, let range = displayAdapter.sourceRange(forDisplay: affectedCharRange) else { return false }
            _ = replaceSource(range: range, with: replacementString)
            return false // The buffer applied the edit; AppKit must not edit the copy.
        }
        guard undoBuffer?.undoManager.workspaceActionInFlight != true else { return false }
        let shouldChange: Bool
        suppressViewUndo = true
        shouldChange = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        suppressViewUndo = false
        if shouldChange {
            pendingCompletionEditRange = affectedCharRange
            if let replacementString { undoBuffer?.registerTextUndo(range: affectedCharRange, replacement: replacementString, coalescing: true) }
        }
        return shouldChange
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        snippetSession = nil
        if let displayAdapter {
            displayAdapter.composition.mark(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
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
        if let displayAdapter { displayAdapter.composition.commit()
        return }
        selectionReplacedByMarkedText = nil
        super.unmarkText()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let displayAdapter else { insertSourceText(insertString, replacementRange: replacementRange)
        return }
        guard isEditable, !sourceSelectedRanges.isEmpty, let text = Self.string(from: insertString) else { return }
        if displayAdapter.composition.isActive {
            displayAdapter.composition.commit(text, replacementRange: replacementRange)
            notifyCompletionChanged()
            return
        }
        if replacementRange.location == NSNotFound {
            insertSourceText(insertString, replacementRange: replacementRange)
        } else if let range = displayAdapter.sourceRange(forDisplay: replacementRange) {
            insertSourceText(insertString, replacementRange: range)
        }
    }

    override func hasMarkedText() -> Bool { displayAdapter?.composition.isActive ?? super.hasMarkedText() }
    override func markedRange() -> NSRange { displayAdapter?.composition.markedRange ?? super.markedRange() }

    override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        guard displayAdapter != nil else { return super.validAttributesForMarkedText() }
        return [.font, .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor, .markedClauseSegment,
                .baselineOffset, .kern, .paragraphStyle, .strikethroughStyle, .strikethroughColor, .writingDirection]
    }

    private func insertSourceText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        if let text = Self.string(from: insertString), snippetSession != nil, !hasMarkedText() {
            let range = replacementRange.location == NSNotFound ? sourceSelectedRange : replacementRange
            if replaceSnippet(range, with: text) { return }
            snippetSession = nil
        }
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
        guard range.location != NSNotFound, NSMaxRange(range) <= (sourceString as NSString).length else {
            insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
            return
        }

        // NEW: Closing delimiter dedent for whitespace-only lines
        if Self.indentationClosingDelimiters.contains(character),
           indentationMode == .bracketAware,
           let edit = IndentationHelper.closingDelimiterEdit(in: sourceString, selectedRange: range, delimiter: character, mode: indentationMode) {
            insertTextAfterTextEdit(edit.replacement, replacementRange: edit.replacementRange)
            setSelectedRangeAfterTextEdit(NSRange(location: edit.replacementRange.location + edit.selectedLocationDelta, length: 0))
            return
        }

        switch PairedDelimiterEditing.resolve(insertedText: text, in: sourceString, selectedRange: range) {
        case let .wrap(opening, closing), let .insertPair(opening, closing):
            insertPairedDelimiter(opening: opening, closing: closing, replacementRange: range)
            return
        case .stepOver:
            setSelectedRangeAfterStepOver(NSRange(location: range.location + 1, length: 0))
            notifySignatureHelpReevaluation()
            return
        case .native:
            break
        }

        insertTextAfterTextEdit(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        if displayAdapter != nil { deleteSourceCharacter(backwards: true)
        return }
        if snippetSession != nil {
            var range = selectedRange()
            if range.length == 0, range.location > 0 { range = (string as NSString).rangeOfComposedCharacterSequence(at: range.location - 1) }
            if replaceSnippet(range, with: "") { return }
            snippetSession = nil
        }
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        super.deleteBackward(sender)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    override func deleteForward(_ sender: Any?) {
        if displayAdapter != nil { deleteSourceCharacter(backwards: false)
        return }
        if snippetSession != nil {
            var range = selectedRange()
            if range.length == 0, range.location < string.utf16.count { range = (string as NSString).rangeOfComposedCharacterSequence(at: range.location) }
            if replaceSnippet(range, with: "") { return }
            snippetSession = nil
        }
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        super.deleteForward(sender)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    override func insertNewline(_ sender: Any?) {
        if displayAdapter != nil, sourceSelectedRanges.isEmpty { return }
        if snippetChoiceWindow.isVisible {
            selectSnippetChoice(at: snippetChoiceSelection)
            return
        }
        if snippetSession != nil, replaceSnippet(sourceSelectedRange, with: "\n") { return }
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
        if cursorsShareLine(ranges, in: sourceString) {
            super.insertNewline(sender)
            return
        }

        var edits: [MultiCursorEdit] = []
        for range in ranges {
            if let edit = IndentationHelper.newlineEdit(in: sourceString, selectedRange: range, mode: indentationMode) {
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
        if displayAdapter != nil, sourceSelectedRanges.isEmpty { return }
        if advanceSnippet(backwards: false) { return }
        if routeCompletionKey(.acceptSelected) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if displayAdapter != nil, sourceSelectedRanges.isEmpty { return }
        if advanceSnippet(backwards: true) { return }
        super.insertBacktab(sender)
    }

    func startSnippet(_ expansion: SnippetExpansion, offset: Int, theme: Theme = .fallback) {
        snippetTheme = theme
        let session = SnippetSession(expansion: expansion, offset: offset)
        snippetSession = session.isFinished ? nil : session
        snippetBufferSnapshot = sourceString
        setSelectedRangeAfterTextEdit(session.selection ?? NSRange(location: offset + expansion.finalCaret, length: 0))
        showSnippetChoices()
    }

    func endSnippet() { snippetSession = nil
    snippetBufferSnapshot = nil }

    private func advanceSnippet(backwards: Bool) -> Bool {
        guard snippetBufferSnapshot == sourceString else { endSnippet()
        return false }
        if !backwards, snippetChoiceWindow.isVisible { selectSnippetChoice(at: snippetChoiceSelection) }
        guard var session = snippetSession, let selection = session.advance(backwards: backwards) else { return false }
        snippetSession = session.isFinished ? nil : session
        setSelectedRangeAfterTextEdit(selection, recordUndoSelection: false)
        showSnippetChoices()
        return true
    }

    private func showSnippetChoices() {
        snippetChoiceWindow.hide()
        guard let session = snippetSession, !session.currentChoices.isEmpty,
              let selected = session.selection, NSMaxRange(selected) <= (sourceString as NSString).length else { return }
        let current = (sourceString as NSString).substring(with: selected)
        snippetChoiceSelection = session.currentChoices.firstIndex(of: current) ?? 0
        snippetChoiceRows = session.currentChoices.map {
            CompletionPopupRow(id: UUID(), label: $0.isEmpty ? "(empty)" : $0, detail: nil, kind: nil, source: .lsp)
        }
        presentSnippetChoices()
    }

    private func presentSnippetChoices() {
        guard let anchor = completionAnchorRect() else { return }
        snippetChoiceWindow.show(rows: snippetChoiceRows, selection: snippetChoiceSelection,
                                 documentation: nil, theme: snippetTheme, anchor: anchor, in: self, compact: true) { [weak self] index in
            self?.selectSnippetChoice(at: index)
        }
    }

    /// Shared by popup clicks and keyboard acceptance; mirrors use the session edit plan.
    func selectSnippetChoice(at index: Int) {
        guard let session = snippetSession, session.currentChoices.indices.contains(index),
              let range = session.selection else { return }
        guard replaceSnippet(range, with: session.currentChoices[index]) else { endSnippet()
        return }
        if let selection = snippetSession?.selection { setSelectedRangeAfterTextEdit(selection) }
        snippetChoiceWindow.hide()
    }

    private func moveSnippetChoice(_ delta: Int) -> Bool {
        guard snippetChoiceWindow.isVisible else { return false }
        guard snippetBufferSnapshot == sourceString else { endSnippet()
        return false }
        snippetChoiceSelection = min(max(0, snippetChoiceSelection + delta), snippetChoiceRows.count - 1)
        presentSnippetChoices()
        return true
    }

    private func replaceSnippet(_ range: NSRange, with text: String) -> Bool {
        guard isEditable, !hasMultipleSelections, !hasMarkedText() else { endSnippet()
        return false }
        guard snippetBufferSnapshot == sourceString else { endSnippet()
        return false }
        guard var session = snippetSession, let plan = session.replacing(range, with: text) else { return false }
        snippetChoiceWindow.hide()
        applyCompletionEdits(plan.edits, finalSelection: plan.finalSelection)
        snippetSession = session
        snippetBufferSnapshot = sourceString
        return true
    }

    override func moveUp(_ sender: Any?) {
        if moveSnippetChoice(-1) { return }
        if routeCompletionKey(.moveSelection(-1)) { return }
        moveAcrossDisplayHints { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if moveSnippetChoice(1) { return }
        if routeCompletionKey(.moveSelection(1)) { return }
        moveAcrossDisplayHints { super.moveDown(sender) }
    }

    private func moveAcrossDisplayHints(_ movement: () -> Void) {
        guard let adapter = displayAdapter, !hasMarkedText(), !adapter.document.map.hintRuns.isEmpty else { movement()
        return }
        let original = sourceSelectedRanges
        let suppressed = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        defer {
            suppressCompletionSelectionNotifications = suppressed
            if !suppressed, sourceSelectedRanges != original { notifyCompletionSelectionChanged() }
        }
        for _ in 0..<(adapter.document.map.hintRuns.count + 2) {
            let previous = selectedRanges
            movement()
            if selectedRanges == previous { break }
            let hasInteriorBoundary = selectedRanges.contains { value in
                let range = value.rangeValue
                return [range.location, NSMaxRange(range)].contains { offset in
                    guard let source = try? adapter.document.map.sourceOffset(forDisplay: offset),
                          let before = try? adapter.document.map.displayOffset(forSource: source, affinity: .beforeHints),
                          let after = try? adapter.document.map.displayOffset(forSource: source, affinity: .afterHints) else { return false }
                    return offset > before && offset < after
                }
            }
            if sourceSelectedRanges != original, !hasInteriorBoundary { break }
        }
    }

    override func moveLeft(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveRight(sender) }
    }

    override func moveForward(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveForward(sender) }
    }

    override func moveBackward(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveBackward(sender) }
    }

    override func moveWordLeft(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordLeft(sender) }
    }

    override func moveWordRight(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordRight(sender) }
    }

    override func moveWordForward(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordForward(sender) }
    }

    override func moveWordBackward(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordBackward(sender) }
    }

    override func moveLeftAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveLeftAndModifySelection(sender) }
    }

    override func moveRightAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveRightAndModifySelection(sender) }
    }

    override func moveForwardAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveForwardAndModifySelection(sender) }
    }

    override func moveBackwardAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveBackwardAndModifySelection(sender) }
    }

    override func moveWordLeftAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordLeftAndModifySelection(sender) }
    }

    override func moveWordRightAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordRightAndModifySelection(sender) }
    }

    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordForwardAndModifySelection(sender) }
    }

    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveWordBackwardAndModifySelection(sender) }
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveUpAndModifySelection(sender) }
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        moveAcrossDisplayHints { super.moveDownAndModifySelection(sender) }
    }

    override func cancelOperation(_ sender: Any?) {
        if let composition = displayAdapter?.composition, composition.isActive { composition.cancel()
        return }
        if routeCompletionKey(.dismiss) { return }
        if snippetSession != nil { snippetSession = nil
        return }
        if escapeHandler?() == true { return }
        if displayAdapter != nil { return }
        super.cancelOperation(sender)
    }

    func completionAnchorRect() -> NSRect? {
        let selection = selectedRange()
        let nsLength = (string as NSString).length
        guard selection.location != NSNotFound, selection.location <= nsLength else { return nil }

        return localInsertionRect(at: selection.location)
    }

    func localInsertionRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        return fallbackInsertionRect(at: location, layoutManager: layoutManager, textContainer: textContainer)
    }

    func applyCompletionEdits(_ edits: [CompletionTextEdit], finalSelection: NSRange) {
        guard isEditable else { return }
        if let adapter = displayAdapter, !adapter.buffer.acceptsSourceInput || adapter.composition.isActive { return }
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
        let range = sourceSelectedRange
        if range.length > 0 {
            super.insertNewline(sender)
            return
        }
        if let edit = IndentationHelper.newlineEdit(in: sourceString, selectedRange: range, mode: indentationMode) {
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
        if inlayHoverHandler?(p) == true { return }
        hoverHandler?(p)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.option, .shift]).isEmpty,
           inlayClickHandler?(convert(event.locationInWindow, from: nil)) == true { return }
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
                let current = normalizedRanges(from: selectedRanges)
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
        _ = inlayHoverHandler?(nil)
        mouseExitedHandler?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, let composition = displayAdapter?.composition, composition.isActive {
            composition.cancel()
            return true
        }
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
        refreshWarningToolTip()
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
        guard !sourceString.isEmpty else { return }

        let ns = sourceString as NSString
        let activeRange: NSRange
        if let last = ranges.last, last.length > 0 {
            activeRange = last
        } else {
            let cursor = ranges.last?.location ?? sourceSelectedRange.location
            guard let word = wordRange(at: cursor) else { return }
            var updated = ranges
            if updated.isEmpty {
                updated = [word]
            } else {
                updated[updated.count - 1] = word
            }
            setSourceSelectedRanges(updated.map(NSValue.init(range:)))
            scrollSourceRangeToVisible(word)
            return
        }

        let needle = ns.substring(with: activeRange)
        guard !needle.isEmpty else { return }
        let searchStart = NSMaxRange(activeRange)
        guard let next = nextUnselectedOccurrence(of: needle, after: searchStart, selected: ranges) else { return }
        setSourceSelectedRanges(sourceSelectedRanges + [NSValue(range: next)])
        scrollSourceRangeToVisible(next)
    }

    private func nextUnselectedOccurrence(of needle: String, after location: Int, selected: [NSRange]) -> NSRange? {
        let ns = sourceString as NSString
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
        let ns = sourceString as NSString
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
        signatureHelpChangeHandler?()
    }

    private func notifyCompletionSelectionChanged() {
        guard !suppressCompletionSelectionNotifications, displayAdapter?.isRebuilding != true else { return }
        if let active = snippetSession?.selection,
           hasMultipleSelections || sourceSelectedRange.location < active.location || NSMaxRange(sourceSelectedRange) > NSMaxRange(active) {
            snippetSession = nil
        }
        undoBuffer?.undoManager.breakTypingCoalescing()
        completionSelectionChangeHandler?()
        signatureHelpSelectionChangeHandler?()
    }

    private func notifySignatureHelpReevaluation() {
        signatureHelpChangeHandler?()
    }

    private func setSelectedRangeAfterTextEdit(_ range: NSRange, recordUndoSelection: Bool = true) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        setSourceSelectedRanges([NSValue(range: range)])
        if recordUndoSelection { displayAdapter?.buffer.recordSourceEditSelection([NSValue(range: range)]) }
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    private func setSelectedRangeAfterStepOver(_ range: NSRange) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        setSourceSelectedRanges([NSValue(range: range)])
        suppressCompletionSelectionNotifications = wasSuppressing
        guard !wasSuppressing else { return }
        undoBuffer?.undoManager.breakTypingCoalescing()
        completionSelectionChangeHandler?()
    }

    private func setSelectedRangesAfterTextEdit(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        setSourceSelectedRanges(ranges)
        displayAdapter?.buffer.recordSourceEditSelection(ranges)
        suppressCompletionSelectionNotifications = wasSuppressing
    }

    private func insertTextAfterTextEdit(_ insertString: Any, replacementRange: NSRange) {
        let wasSuppressing = suppressCompletionSelectionNotifications
        suppressCompletionSelectionNotifications = true
        if let displayAdapter, let text = Self.string(from: insertString) {
            let range = effectiveReplacementRange(replacementRange)
            let original = sourceString
            pendingCompletionEditRange = range
            if displayAdapter.replaceSource(range, with: text), !EditorSourceText.exactlyEqual(original, sourceString) { didChangeText() }
            else { pendingCompletionEditRange = nil }
        } else {
            super.insertText(insertString, replacementRange: replacementRange)
        }
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
        replacementRange.location == NSNotFound ? sourceSelectedRange : replacementRange
    }

    private func insertPairedDelimiter(opening: Character, closing: Character, replacementRange range: NSRange) {
        let current = sourceString as NSString
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
            setSelectedRangeAfterStepOver(NSRange(location: marked.location + 1, length: 0))
            notifySignatureHelpReevaluation()
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
        guard let charIndex = utf16Offset(at: point) else { return nil }
        let nsString = sourceString as NSString
        guard charIndex < nsString.length else { return nil }
        let range = nsString.rangeOfWord(at: charIndex)
        return range.length == 0 ? nil : range
    }

    /// Returns the bounding rect (in view coordinates, including
    /// `textContainerInset`) of the first character of `range`. Used to anchor
    /// the hover popover under a token.
    func symbolAnchorRect(for range: NSRange) -> NSRect? {
        sourceRects(inViewFor: range).first
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
