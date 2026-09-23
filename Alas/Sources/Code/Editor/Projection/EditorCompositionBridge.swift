import AppKit

@MainActor
final class EditorCompositionBridge {
    private unowned let adapter: EditorDisplayAdapter
    private struct State {
        let owner: UUID
        let original: String
        let selections: [NSValue]
        let originalRange: NSRange
        let typingAttributes: [NSAttributedString.Key: Any]
        var range: NSRange
        var attributed: NSAttributedString
    }
    private var state: State?
    var isActive: Bool { state != nil }
    var sourceTypingAttributes: [NSAttributedString.Key: Any]? { state?.typingAttributes }
    var markedRange: NSRange { state.flatMap { adapter.displayRange(forSource: $0.range) } ?? NSRange(location: NSNotFound, length: 0) }

    init(adapter: EditorDisplayAdapter) { self.adapter = adapter }

    func mark(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let view = adapter.view, view.isEditable else { return }
        let attributed: NSAttributedString
        if let supplied = value as? NSAttributedString { attributed = NSAttributedString(attributedString: supplied) }
        else if let supplied = value as? String { attributed = NSAttributedString(string: supplied, attributes: view.markedTextAttributes) }
        else { return }
        guard selectedRange.location >= 0, selectedRange.length >= 0,
              selectedRange.location <= attributed.length, selectedRange.length <= attributed.length - selectedRange.location,
              let selectionMap = try? EditorDisplayMap(source: attributed.string, revision: 0, hints: []),
              (try? selectionMap.displaySegments(forSource: selectedRange)) != nil else { return }
        let nativeRange = replacementRange.location == NSNotFound ? (isActive ? markedRange : view.selectedRange()) : replacementRange
        guard let sourceRange = adapter.sourceRange(forDisplay: nativeRange) else { return }
        if state == nil {
            let owner = UUID()
            guard adapter.buffer.beginComposition(owner: owner, settle: { [weak self] in self?.commit() }, invalidate: { [weak self] in self?.invalidate() }) else { return }
            state = State(owner: owner, original: adapter.buffer.storage.string, selections: view.sourceSelectedRanges, originalRange: sourceRange,
                          typingAttributes: view.typingAttributes, range: sourceRange, attributed: attributed)
        }
        guard var current = state else { return }
        // Overlay coordinates describe the replacement, including explicit absolute
        // replacement ranges outside the previous marked run.
        current.range = NSRange(location: sourceRange.location, length: attributed.length)
        current.attributed = attributed
        state = current
        guard adapter.replaceSource(sourceRange, with: attributed.string, composition: current.owner) else { invalidate()
        return }
        applyOverlay()
        view.restoreSourceSelections([NSValue(range: NSRange(location: sourceRange.location + selectedRange.location, length: selectedRange.length))])
        view.inputContext?.invalidateCharacterCoordinates()
    }

    func commit(_ text: String? = nil, replacementRange: NSRange = NSRange(location: NSNotFound, length: 0)) {
        guard let current = state else { return }
        if let text {
            let nativeRange = replacementRange.location == NSNotFound ? markedRange : replacementRange
            guard let range = adapter.sourceRange(forDisplay: nativeRange) else { return }
            var replacement = text
            var finalSelection: NSRange?
            var steppedOver = false
            if adapter.view?.autoPairDisabled == false, text.count == 1, EditorSourceText.exactlyEqual(text, current.attributed.string),
               range == current.range {
                switch PairedDelimiterEditing.resolve(insertedText: text, in: current.original, selectedRange: current.originalRange) {
                case let .wrap(opening, closing), let .insertPair(opening, closing):
                    let original = (current.original as NSString).substring(with: current.originalRange)
                    replacement = "\(opening)\(original)\(closing)"
                    finalSelection = NSRange(location: range.location + 1, length: current.originalRange.length)
                case .stepOver:
                    replacement = ""
                    finalSelection = NSRange(location: range.location + 1, length: 0)
                    steppedOver = true
                case .native: break
                }
            }
            guard adapter.replaceSource(range, with: replacement, composition: current.owner) else { return }
            if let finalSelection { adapter.view?.restoreSourceSelections([NSValue(range: finalSelection)]) }
            if steppedOver {
                adapter.view?.completionSelectionChangeHandler?()
                adapter.view?.signatureHelpChangeHandler?()
            }
        }
        let final = adapter.buffer.storage.string
        let change = EditorSourceDifference(from: current.original, to: final)
        let old = (current.original as NSString).substring(with: change.range)
        let finalSelections = adapter.view?.sourceSelectedRanges ?? []
        state = nil
        adapter.buffer.endComposition(owner: current.owner)
        adapter.buffer.registerSourceInverse(range: NSRange(location: change.range.location, length: change.replacement.utf16.count),
                                             expected: change.replacement, replacement: old, selections: finalSelections, restoredSelections: current.selections)
        adapter.finishCompositionPresentation(restoring: NSRange(location: change.range.location, length: change.replacement.utf16.count))
    }

    func cancel() {
        guard let current = state else { return }
        let change = EditorSourceDifference(from: adapter.buffer.storage.string, to: current.original)
        guard adapter.replaceSource(change.range, with: change.replacement, composition: current.owner) else { invalidate()
        return }
        state = nil
        adapter.buffer.endComposition(owner: current.owner)
        adapter.finishCompositionPresentation(restoring: NSRange(location: change.range.location, length: change.replacement.utf16.count))
        adapter.view?.restoreSourceSelections(current.selections)
    }

    /// Foreign character edits win. Never write the old composition snapshot back.
    func invalidate() {
        guard let current = state else { return }
        state = nil
        adapter.buffer.endComposition(owner: current.owner)
        adapter.finishCompositionPresentation(restoring: current.range)
    }

    func applyOverlay() {
        guard let current = state, let display = adapter.displayRange(forSource: current.range),
              display.length == current.attributed.length, NSMaxRange(display) <= adapter.document.storage.length else { return }
        current.attributed.enumerateAttributes(in: NSRange(location: 0, length: current.attributed.length)) { attributes, range, _ in
            var attributes = attributes
            // A marked string may style its source characters; it cannot install
            // virtual attachment objects into the document's source runs.
            attributes.removeValue(forKey: .attachment)
            adapter.document.storage.addAttributes(attributes, range: NSRange(location: display.location + range.location, length: range.length))
        }
    }
}
