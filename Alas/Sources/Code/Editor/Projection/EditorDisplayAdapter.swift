import AppKit

/// One native view owns one display document. Source history stays in its buffer.
@MainActor
final class EditorDisplayAdapter {
    let buffer: EditorBuffer
    let document: EditorDisplayDocument
    weak var view: CodeTextView?
    lazy var composition = EditorCompositionBridge(adapter: self)
    private var editObserver: EditorBuffer.EditObserverToken?
    private var attributeObserver: NSObjectProtocol?
    private var selectionObserver: UUID?
    private var hints: [EditorDisplayHint] = []
    private var sourceSnapshot: String
    private(set) var sourceLineStarts: [Int]
    private var deferredHints: (revision: Int, hints: [EditorDisplayHint])?
    private(set) var isApplyingSourceEdit = false
    private(set) var isRebuilding = false

    init(buffer: EditorBuffer, view: CodeTextView) throws {
        self.buffer = buffer
        self.view = view
        sourceSnapshot = buffer.storage.string
        sourceLineStarts = Self.lineStarts(in: buffer.storage.string)
        document = try EditorDisplayDocument(source: buffer.storage, revision: buffer.editGeneration, hints: [])
        editObserver = buffer.onTextEdit { [weak self] _ in self?.sourceChanged() }
        selectionObserver = buffer.observeSourceSelection { [weak self] ranges in
            self?.view?.restoreSourceSelections(ranges)
        }
        attributeObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: buffer.storage, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.buffer.storage.editedMask.contains(.editedCharacters) {
                    // Programmatic reloads suppress onTextEdit while installing
                    // text, but the separate display still needs the new source.
                    if self.document.map.revision != self.buffer.editGeneration || !EditorSourceText.exactlyEqual(self.sourceSnapshot, self.buffer.storage.string) { self.sourceChanged() }
                } else { self.rebuild() }
            }
        }
    }

    func detach() {
        composition.commit()
        if let editObserver { buffer.removeOnEdit(editObserver) }
        if let selectionObserver { buffer.removeSourceSelectionObserver(selectionObserver) }
        if let attributeObserver { NotificationCenter.default.removeObserver(attributeObserver) }
        editObserver = nil
        selectionObserver = nil
        attributeObserver = nil
        if let manager = view?.layoutManager, manager.textStorage === document.storage {
            document.storage.removeLayoutManager(manager)
        }
        view = nil
    }

    /// LSP injection is intentionally unwired until all source consumers migrate.
    func updateHints(_ hints: [EditorDisplayHint], revision: Int) throws {
        guard revision == buffer.editGeneration else { return }
        _ = try EditorDisplayMap(source: buffer.storage.string, revision: revision, hints: hints)
        if composition.isActive { deferredHints = (revision, hints)
        return }
        self.hints = hints
        rebuild()
    }

    func sourceRange(forDisplay range: NSRange) -> NSRange? {
        guard document.map.revision == buffer.editGeneration else { return nil }
        return try? document.map.sourceRange(forDisplay: range)
    }

    func displayRange(forSource range: NSRange) -> NSRange? {
        guard document.map.revision == buffer.editGeneration,
              range.location >= 0, range.location <= buffer.storage.length, range.length >= 0,
              range.length <= buffer.storage.length - range.location,
              let start = try? document.map.displayOffset(forSource: range.location, affinity: .afterHints),
              let end = try? document.map.displayOffset(forSource: NSMaxRange(range), affinity: range.length == 0 ? .afterHints : .beforeHints)
        else { return nil }
        return NSRange(location: start, length: max(0, end - start))
    }

    @discardableResult
    func replaceSource(_ range: NSRange, with text: String, composition owner: UUID? = nil) -> Bool {
        guard let view, view.isEditable,
              range.location >= 0, range.location <= buffer.storage.length,
              range.length >= 0, range.length <= buffer.storage.length - range.location else { return false }
        let selections = view.sourceSelectedRanges
        guard !selections.isEmpty else { return false }
        var attributes = composition.sourceTypingAttributes ?? view.typingAttributes
        attributes.removeValue(forKey: .attachment)
        attributes.removeValue(forKey: .markedClauseSegment)
        let final = [NSValue(range: NSRange(location: range.location + text.utf16.count, length: 0))]
        isApplyingSourceEdit = true
        defer { isApplyingSourceEdit = false }
        guard buffer.replaceSource(range: range, with: text, selections: selections, finalSelections: final, composition: owner, attributes: attributes) else { return false }
        view.restoreSourceSelections(final)
        return true
    }

    func beginCompositionPresentation() {
        hints = []
        rebuild()
    }

    func finishCompositionPresentation() {
        if let pending = deferredHints, pending.revision == buffer.editGeneration { hints = pending.hints }
        deferredHints = nil
        rebuild()
        view?.inputContext?.discardMarkedText()
    }

    private func sourceChanged() {
        if composition.isActive, !isApplyingSourceEdit { composition.invalidate() }
        hints = [] // Server anchors are stale after every source character edit.
        sourceLineStarts = Self.lineStarts(in: buffer.storage.string)
        rebuild()
        if let view { NotificationCenter.default.post(name: .editorSourceDidChange, object: view) }
    }

    static func lineStarts(in text: String) -> [Int] {
        var result = [0]
        for (offset, unit) in text.utf16.enumerated() where unit == 10 { result.append(offset + 1) }
        return result
    }

    func rebuild() {
        guard !isRebuilding, let view else { return }
        isRebuilding = true
        defer { isRebuilding = false }
        // The old document remains the source coordinate map for native selections.
        let selections = view.selectedRanges.compactMap { try? document.map.sourceRange(forDisplay: $0.rangeValue) }.map(NSValue.init(range:))
        let typingAttributes = view.typingAttributes
        let scroll = captureScrollAnchor()
        if let layout = view.layoutManager {
            let range = NSRange(location: 0, length: document.storage.length)
            for key in [NSAttributedString.Key.foregroundColor, .backgroundColor, .underlineStyle, .underlineColor,
                        NSAttributedString.Key("alas.editorFindHighlightMarker"), NSAttributedString.Key("alas.editorFindPreviousBackgroundColor")] {
                layout.removeTemporaryAttribute(key, forCharacterRange: range)
            }
        }
        do {
            try document.replace(source: buffer.storage, revision: buffer.editGeneration, hints: hints)
        } catch {
            // Reject bad presentation metadata without mutating authoritative text.
            hints = []
            do { try document.replace(source: buffer.storage, revision: buffer.editGeneration, hints: []) }
            catch { return }
        }
        sourceSnapshot = buffer.storage.string
        composition.applyOverlay()
        let clipped = selections.map { value -> NSValue in
            let range = value.rangeValue
            let source = buffer.storage.string as NSString
            func boundary(_ offset: Int) -> Int {
                let clipped = min(offset, source.length)
                if clipped > 0, clipped < source.length,
                   (0xDC00 ... 0xDFFF).contains(source.character(at: clipped)),
                   (0xD800 ... 0xDBFF).contains(source.character(at: clipped - 1)) { return clipped - 1 }
                return clipped
            }
            let start = boundary(range.location)
            return NSValue(range: NSRange(location: start, length: max(0, boundary(NSMaxRange(range)) - start)))
        }
        view.restoreSourceSelections(clipped)
        // Empty storage has no character from which AppKit can recover typing
        // style. Keep the configured style across delete-all and reload.
        if buffer.storage.length == 0 { view.typingAttributes = typingAttributes }
        restoreScrollAnchor(scroll)
        view.inputContext?.invalidateCharacterCoordinates()
        if view.snippetChoiceWindow.isVisible, let rect = view.completionAnchorRect() {
            view.snippetChoiceWindow.reposition(anchor: rect, in: view)
        }
        NotificationCenter.default.post(name: .editorDisplayProjectionDidChange, object: view)
    }

    struct ScrollAnchor { let sourceLine: Int
    let delta: CGFloat
    let x: CGFloat }

    func captureScrollAnchor() -> ScrollAnchor? {
        guard let view, let scroll = view.enclosingScrollView, let manager = view.layoutManager,
              let container = view.textContainer, document.storage.length > 0 else { return nil }
        let origin = scroll.contentView.bounds.origin
        let point = NSPoint(x: 0, y: origin.y - view.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs,
              let source = try? document.map.sourceOffset(forDisplay: manager.characterIndexForGlyph(at: glyph)) else { return nil }
        let oldSource = sourceSnapshot as NSString
        guard source <= oldSource.length else { return nil }
        let line = oldSource.lineRange(for: NSRange(location: source, length: 0)).location
        guard let lineDisplay = try? document.map.displayOffset(forSource: line, affinity: .afterHints),
              lineDisplay < document.storage.length else { return nil }
        let lineGlyph = manager.glyphIndexForCharacter(at: lineDisplay)
        let lineY = manager.lineFragmentRect(forGlyphAt: lineGlyph, effectiveRange: nil).minY
        // Measure from the source line's first fragment, including any wrapped
        // fragments above the viewport in its saved pixel displacement.
        return ScrollAnchor(sourceLine: line, delta: origin.y - lineY - view.textContainerOrigin.y, x: origin.x)
    }

    func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, let view, let scroll = view.enclosingScrollView, let manager = view.layoutManager,
              let container = view.textContainer, let range = displayRange(forSource: NSRange(location: min(anchor.sourceLine, buffer.storage.length), length: 0)),
              range.location < document.storage.length else { return }
        manager.ensureLayout(for: container)
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        let y = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerOrigin.y + anchor.delta
        scroll.contentView.scroll(to: NSPoint(x: anchor.x, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// Source identity is exact UTF-16, not Swift's canonical Unicode equivalence.
enum EditorSourceText {
    static func exactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}

/// A minimal replacement whose boundaries never split extended graphemes.
struct EditorSourceDifference {
    let range: NSRange
    let replacement: String
    init(from original: String, to final: String) {
        let before = Array(original)
        let after = Array(final)
        var start = 0
        while start < min(before.count, after.count), EditorSourceText.exactlyEqual(String(before[start]), String(after[start])) { start += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - start,
              EditorSourceText.exactlyEqual(String(before[before.count - 1 - suffix]), String(after[after.count - 1 - suffix])) { suffix += 1 }
        let prefixLength = String(before[..<start]).utf16.count
        range = NSRange(location: prefixLength, length: String(before[start..<(before.count - suffix)]).utf16.count)
        replacement = String(after[start..<(after.count - suffix)])
    }
}
