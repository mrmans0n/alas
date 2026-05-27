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

    static func restyle(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }

        let baseFont = NSFont.systemFont(ofSize: 13)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        storage.beginEditing()
        // Reset to defaults — but preserve our chip attribute so existing
        // mentions don't get bulldozed by every keystroke.
        storage.enumerateAttribute(.attachmentURI, in: full) { value, range, _ in
            if value == nil {
                storage.setAttributes([
                    .font: baseFont,
                    .foregroundColor: NSColor.labelColor,
                ], range: range)
            }
        }

        apply(regex: bold, in: storage, range: full, attrs: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        apply(regex: italicStar, in: storage, range: full, attrs: [
            .font: NSFontManager.shared.font(withFamily: NSFont.systemFont(ofSize: 13).familyName ?? "System",
                                             traits: .italicFontMask, weight: 5, size: 13)
                ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        apply(regex: italicUnder, in: storage, range: full, attrs: [
            .font: NSFontManager.shared.font(withFamily: NSFont.systemFont(ofSize: 13).familyName ?? "System",
                                             traits: .italicFontMask, weight: 5, size: 13)
                ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        apply(regex: code, in: storage, range: full, attrs: [
            .font: codeFont,
            .foregroundColor: NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.92, alpha: 1),
            .backgroundColor: NSColor.white.withAlphaComponent(0.06),
        ])

        storage.endEditing()
    }

    private static func apply(regex: NSRegularExpression,
                               in storage: NSTextStorage,
                               range: NSRange,
                               attrs: [NSAttributedString.Key: Any]) {
        let str = storage.string as NSString
        regex.enumerateMatches(in: storage.string, range: range) { match, _, _ in
            guard let m = match else { return }
            // Don't double-style chip mentions.
            var skip = false
            storage.enumerateAttribute(.attachmentURI, in: m.range) { v, _, stop in
                if v != nil { skip = true; stop.pointee = true }
            }
            if skip { return }
            storage.addAttributes(attrs, range: m.range)
            _ = str
        }
    }
}
