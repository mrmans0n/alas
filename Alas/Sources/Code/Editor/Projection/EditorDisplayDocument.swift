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

    private static func assemble(source: NSAttributedString, map: EditorDisplayMap) -> NSAttributedString {
        let display = NSMutableAttributedString(string: "")
        var cursor = 0
        for run in map.hintRuns {
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
        if cursor < source.length {
            display.append(source.attributedSubstring(from: NSRange(location: cursor, length: source.length - cursor)))
        }
        return display
    }
}
