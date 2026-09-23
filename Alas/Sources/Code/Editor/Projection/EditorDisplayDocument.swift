import AppKit

@MainActor
final class EditorDisplayDocument {
    /// This storage belongs to the display document, never to EditorBuffer.
    /// Keep its identity stable so native layout managers remain attached.
    let storage: NSTextStorage
    private(set) var map: EditorDisplayMap

    init(source: NSAttributedString, revision: Int, hints: [EditorDisplayHint]) throws {
        let map = try EditorDisplayMap(source: source.string, revision: revision, hints: hints)
        let display = Self.assemble(source: source, map: map)
        self.map = map
        // NSTextStorage may select effective fallback fonts for unsupported
        // glyphs. The supplied source retains its requested font attributes.
        storage = NSTextStorage(attributedString: display)
    }

    /// Validation and attributed assembly complete before the live map or storage
    /// changes. Publishing the map before endEditing keeps layout observers current.
    func replace(source: NSAttributedString, revision: Int, hints: [EditorDisplayHint]) throws {
        let replacementMap = try EditorDisplayMap(source: source.string, revision: revision, hints: hints)
        let display = Self.assemble(source: source, map: replacementMap)
        storage.beginEditing()
        map = replacementMap
        storage.setAttributedString(display)
        storage.endEditing()
    }

    /// A hint response changes only presentation at the current source revision.
    /// Preserve text outside the old/new hint extent so TextKit can reuse layout
    /// above the viewport instead of laying out the document from the beginning.
    func replaceHints(source: NSAttributedString, revision: Int, hints: [EditorDisplayHint]) throws {
        guard revision == map.revision, source.length == map.sourceLength else {
            try replace(source: source, revision: revision, hints: hints)
            return
        }
        let replacementMap = try EditorDisplayMap(source: source.string, revision: revision, hints: hints)
        let old = map.hintRuns, new = replacementMap.hintRuns
        var first = 0
        while first < min(old.count, new.count), old[first].hint == new[first].hint { first += 1 }
        var oldEnd = old.count, newEnd = new.count
        while oldEnd > first, newEnd > first, old[oldEnd - 1].hint == new[newEnd - 1].hint {
            oldEnd -= 1
            newEnd -= 1
        }
        let changedOld = old[first..<oldEnd], changedNew = new[first..<newEnd]
        let offsets = [changedOld.first?.hint.sourceOffset, changedOld.last?.hint.sourceOffset,
                       changedNew.first?.hint.sourceOffset, changedNew.last?.hint.sourceOffset].compactMap { $0 }
        guard let start = offsets.min(), let end = offsets.max() else {
            map = replacementMap
            return
        }
        let displayStart = try map.displayOffset(forSource: start, affinity: .beforeHints)
        let displayEnd = try map.displayOffset(forSource: end, affinity: .afterHints)
        let display = Self.assemble(source: source, map: replacementMap, range: NSRange(location: start, length: end - start))
        storage.beginEditing()
        map = replacementMap
        storage.replaceCharacters(in: NSRange(location: displayStart, length: displayEnd - displayStart), with: display)
        storage.endEditing()
    }

    /// Applies one committed source edit, optionally retaining hints outside
    /// touched lines as presentation only. The caller
    /// supplies the buffer's edit event, so unchanged prefix/suffix text need
    /// not be copied or compared. Reloads and uncertain revisions rebuild.
    func applySourceEdit(_ edit: EditorTextEdit, source: NSAttributedString, revision: Int, preservingUneditedLineHints: Bool = false) -> Bool {
        guard (map.hintRuns.isEmpty || preservingUneditedLineHints), revision == map.revision &+ 1,
              (try? map.displaySegments(forSource: edit.oldRange)) != nil,
              source.length >= map.sourceLength - edit.oldLength,
              source.length - (map.sourceLength - edit.oldLength) == edit.newLength else { return false }
        var retained: [EditorDisplayHint] = []
        if !map.hintRuns.isEmpty {
            for run in map.hintRuns {
                let hint = run.hint
                let offset = hint.sourceOffset
                let oldEnd = NSMaxRange(edit.oldRange)
                if edit.oldLength > 0, offset >= edit.location, offset < oldEnd { continue }
                let shifted = offset < edit.location ? offset : offset + edit.newLength - edit.oldLength
                retained.append(.init(id: hint.id, sourceOffset: shifted, label: hint.label,
                                      size: hint.size, parts: hint.parts, fontSize: hint.fontSize))
            }
        }
        guard let replacementMap = try? EditorDisplayMap(source: source.string, revision: revision, hints: retained),
              (try? replacementMap.displaySegments(forSource: edit.newRange)) != nil,
              let displayStart = try? map.displayOffset(forSource: edit.location, affinity: .beforeHints),
              let displayEnd = try? map.displayOffset(forSource: NSMaxRange(edit.oldRange), affinity: .beforeHints),
              EditorSourceText.exactlyEqual(source.attributedSubstring(from: edit.newRange).string, edit.replacementText) else { return false }
        let replacement = source.attributedSubstring(from: edit.newRange)
        storage.beginEditing()
        map = replacementMap
        storage.replaceCharacters(in: NSRange(location: displayStart, length: displayEnd - displayStart), with: replacement)
        storage.endEditing()
        return true
    }

    /// Paint changes do not alter coordinates or hint geometry. Validate every
    /// affected run before writing, so layout-affecting changes can fall back
    /// to a complete rebuild without publishing a partial update.
    func updatePaintAttributes(source: NSAttributedString, revision: Int, range: NSRange) -> Bool {
        guard revision == map.revision, source.length == map.sourceLength,
              (try? map.displaySegments(forSource: range)) != nil else { return false }
        let paintKeys: Set<NSAttributedString.Key> = [
            .foregroundColor, .backgroundColor, .underlineStyle, .underlineColor,
            .strikethroughStyle, .strikethroughColor
        ]
        var updates: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        var compatible = true
        source.enumerateAttributes(in: range) { attributes, sourceRange, stop in
            guard let segments = try? map.displaySegments(forSource: sourceRange) else {
                compatible = false
                stop.pointee = true
                return
            }
            let layoutAttributes = attributes.filter { !paintKeys.contains($0.key) }
            let paintAttributes = attributes.filter { paintKeys.contains($0.key) }
            for segment in segments {
                storage.enumerateAttributes(in: segment) { previous, displayRange, innerStop in
                    guard NSDictionary(dictionary: layoutAttributes).isEqual(to: previous.filter { !paintKeys.contains($0.key) }) else {
                        compatible = false
                        innerStop.pointee = true
                        return
                    }
                    if !NSDictionary(dictionary: paintAttributes).isEqual(to: previous.filter { paintKeys.contains($0.key) }) {
                        updates.append((displayRange, paintAttributes))
                    }
                }
                if !compatible { stop.pointee = true
                return }
            }
        }
        guard compatible else { return false }
        guard !updates.isEmpty else { return true }
        storage.beginEditing()
        for update in updates {
            for key in paintKeys { storage.removeAttribute(key, range: update.range) }
            storage.addAttributes(update.attributes, range: update.range)
        }
        storage.endEditing()
        return true
    }

    /// Removes marked-text presentation from source characters without replacing
    /// the display document or its hint attachments.
    func restoreSourceAttributes(source: NSAttributedString, revision: Int, range: NSRange) -> Bool {
        guard revision == map.revision, source.length == map.sourceLength,
              range.location >= 0, range.length >= 0, NSMaxRange(range) <= source.length,
              (try? map.displaySegments(forSource: range)) != nil else { return false }
        guard range.length > 0 else { return true }
        var updates: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
        var valid = true
        source.enumerateAttributes(in: range) { attributes, sourceRange, stop in
            guard let segments = try? map.displaySegments(forSource: sourceRange) else {
                valid = false
                stop.pointee = true
                return
            }
            var attributes = attributes
            attributes.removeValue(forKey: .attachment)
            updates.append(contentsOf: segments.map { ($0, attributes) })
        }
        guard valid else { return false }
        storage.beginEditing()
        for update in updates { storage.setAttributes(update.attributes, range: update.range) }
        storage.endEditing()
        return true
    }

    private static func assemble(source: NSAttributedString, map: EditorDisplayMap, range: NSRange? = nil) -> NSAttributedString {
        let display = NSMutableAttributedString(string: "")
        let range = range ?? NSRange(location: 0, length: source.length)
        var cursor = range.location
        let end = NSMaxRange(range)
        for run in map.hintRuns where run.hint.sourceOffset >= range.location && run.hint.sourceOffset <= end {
            let offset = run.hint.sourceOffset
            if offset > cursor {
                display.append(source.attributedSubstring(from: NSRange(location: cursor, length: offset - cursor)))
            }
            let attachment = NSMutableAttributedString(attachment: EditorHintAttachment(hint: run.hint))
            // Hints inherit local layout attributes, including the paragraph's
            // writing direction and tab stops. They own their attachment value.
            if source.length > 0 {
                let attributes = source.attributes(at: min(offset, source.length - 1), effectiveRange: nil).filter {
                    [.font, .paragraphStyle, .writingDirection].contains($0.key)
                }
                attachment.addAttributes(attributes, range: NSRange(location: 0, length: 1))
            }
            display.append(attachment)
            cursor = offset
        }
        if cursor < end {
            display.append(source.attributedSubstring(from: NSRange(location: cursor, length: end - cursor)))
        }
        return display
    }
}
