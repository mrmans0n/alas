import AppKit

/// Re-style an NSTextStorage so basic inline markdown (`**bold**`,
/// `*italic*` / `_italic_`, `` `code` ``) renders styled while the user
/// types. The literal markers stay in the storage so the submitted text
/// is still proper markdown — the receiving side parses it again.
///
/// Non-markdown text is reset to the default 13pt label colour so
/// applying then removing a marker cleans up old attributes.
enum ACPMarkdownLiveStyler {
    private static let bold = try! NSRegularExpression(pattern: "\\*\\*([^*\\n]+?)\\*\\*")
    private static let italicStar = try! NSRegularExpression(pattern: "(?<!\\*)\\*([^*\\n]+?)\\*(?!\\*)")
    private static let italicUnder = try! NSRegularExpression(pattern: "(?<!_)_([^_\\n]+?)_(?!_)")
    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+?)`")

    static func restyle(
        _ storage: NSTextStorage,
        typography: ACPChatTypography = .default,
        excluding excludedRanges: [NSRange] = []
    ) {
        restyle(storage, in: nil, typography: typography, excluding: excludedRanges)
    }

    static func restyle(
        _ storage: NSTextStorage,
        in requestedRange: NSRange?,
        typography: ACPChatTypography = .default,
        excluding excludedRanges: [NSRange] = []
    ) {
        guard storage.length > 0 else { return }

        // Restrict the styling work to the line(s) touched by the latest
        // edit. The regex patterns above never cross a newline, so any
        // span that could need (re)styling is contained in the lineRange
        // of the edited range. We need BOTH the line at the start of the
        // edit and the line at the end — inserting a newline puts the
        // insertion point at the boundary, and `lineRange(for:)` of just
        // the start would miss the freshly-orphaned line below. On a
        // fresh restyle with no edit info, fall back to full storage.
        let target: NSRange
        if let requestedRange {
            target = lineRangeCovering(requestedRange, in: storage)
        } else if let edited = editedLineRange(in: storage) {
            target = edited
        } else {
            target = NSRange(location: 0, length: storage.length)
        }
        guard target.length > 0 else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        let baseFont = typography.appKitFont()
        let boldFont = typography.appKitFont(traits: .boldFontMask)
        let italicFont = typography.appKitFont(traits: .italicFontMask)
        let codeFont = typography.appKitFont(size: typography.codeSize)

        // Reset to defaults — but preserve our chip attributes so existing
        // mention AND image chips don't get bulldozed (their `.attachment`
        // cell stripped) by every keystroke's restyle.
        storage.enumerateAttributes(in: target) { attrs, range, _ in
            guard attrs[.attachmentURI] == nil, attrs[.imageAttachmentURI] == nil else { return }
            guard !Self.intersects(range, excludedRanges) else { return }
            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ], range: range)
        }

        apply(regex: bold, in: storage, range: target, attrs: [
            .font: boldFont,
            .foregroundColor: NSColor.labelColor,
        ], excluding: excludedRanges)
        let italicAttrs: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: NSColor.labelColor,
        ]
        apply(regex: italicStar, in: storage, range: target, attrs: italicAttrs, excluding: excludedRanges)
        apply(regex: italicUnder, in: storage, range: target, attrs: italicAttrs, excluding: excludedRanges)
        apply(regex: code, in: storage, range: target, attrs: [
            .font: codeFont,
            .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.92, alpha: 1),
            .backgroundColor: NSColor.white.withAlphaComponent(0.06),
        ], excluding: excludedRanges)
    }

    static func editedLineRange(in storage: NSTextStorage) -> NSRange? {
        let edited = storage.editedRange
        guard edited.location != NSNotFound, edited.location <= storage.length else {
            return nil
        }
        return lineRangeCovering(edited, in: storage)
    }

    private static func lineRangeCovering(_ range: NSRange, in storage: NSTextStorage) -> NSRange {
        let nsString = storage.string as NSString
        let startLoc = min(range.location, storage.length)
        let endLoc = min(range.location + range.length, storage.length)
        let startLine = nsString.lineRange(for: NSRange(location: startLoc, length: 0))
        let endLine = nsString.lineRange(for: NSRange(location: endLoc, length: 0))
        return NSUnionRange(startLine, endLine)
    }

    private static func apply(regex: NSRegularExpression,
                              in storage: NSTextStorage,
                              range: NSRange,
                              attrs: [NSAttributedString.Key: Any],
                              excluding excludedRanges: [NSRange] = []) {
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let m = match else { return }
            guard !intersects(m.range, excludedRanges) else { return }
            // Don't double-style chip mentions or image chips.
            var skip = false
            storage.enumerateAttributes(in: m.range) { attrs, _, stop in
                if attrs[.attachmentURI] != nil || attrs[.imageAttachmentURI] != nil {
                    skip = true
                    stop.pointee = true
                }
            }
            if skip { return }
            storage.addAttributes(attrs, range: m.range)
        }
    }

    private static func intersects(_ range: NSRange, _ others: [NSRange]) -> Bool {
        others.contains { NSIntersectionRange(range, $0).length > 0 }
    }

    /// The span that must be restyled when the set of fenced blocks changed.
    ///
    /// A single new ``` flips the open/closed parity of every block below it,
    /// so the range runs from the first differing fence to end of storage.
    /// Returns nil when the fence set is unchanged, in which case the caller
    /// keeps its existing edited-line-range behaviour.
    static func dirtyRange(
        previous: [FencedBlock],
        current: [FencedBlock],
        storageLength: Int
    ) -> NSRange? {
        let previousFences = previous.map(\.openFenceRange.location)
        let currentFences = current.map(\.openFenceRange.location)
        guard previousFences != currentFences else { return nil }

        let firstDifference = zip(previousFences, currentFences)
            .first { $0 != $1 }
            .map { min($0, $1) }
            ?? (previousFences + currentFences).min()
            ?? 0
        let start = max(0, min(firstDifference, storageLength))
        return NSRange(location: start, length: storageLength - start)
    }
}
