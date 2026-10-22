import Foundation

/// What of a setup screen fits the terminal: a long list scrolls and a wide
/// row is cut, so a small SSH window still shows the selection.
public enum HostSetupViewport {
    /// The rows of `count` that `height` lines show: all of them when they
    /// fit, otherwise a window centred on `selected` where the list allows.
    public static func visibleRows(count: Int, selected: Int, height: Int) -> Range<Int> {
        let height = max(height, 1)
        guard count > height else { return 0 ..< count }
        let start = min(max(selected - height / 2, 0), count - height)
        return start ..< start + height
    }

    /// `row` cut to `width` terminal cells, with an ellipsis where it was cut:
    /// at the end, or at the start when `keepingEnd`, as for a value being
    /// edited, whose cursor is at its end.
    public static func fit(_ row: String, width: Int, keepingEnd: Bool = false) -> String {
        guard cells(row) > width else { return row }
        guard width > 0 else { return "" }
        var budget = max(width - 1, 0)
        var kept: [Character] = []
        for character in keepingEnd ? Array(row.reversed()) : Array(row) {
            let size = cells(character)
            guard size <= budget else { break }
            budget -= size
            kept.append(character)
        }
        return keepingEnd ? "…" + String(kept.reversed()) : String(kept) + "…"
    }

    /// The terminal cells `text` takes.
    public static func cells(_ text: String) -> Int {
        text.reduce(0) { $0 + cells($1) }
    }

    /// Two for a wide character (CJK, Hangul, fullwidth forms, emoji), none
    /// for combining marks alone, one otherwise.
    // ponytail: hand-kept East Asian Wide ranges, swap for a full width table if rows misalign.
    static func cells(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if scalars.allSatisfy({ [.nonspacingMark, .enclosingMark].contains($0.properties.generalCategory) }) { return 0 }
        if first.properties.isEmojiPresentation || scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        switch first.value {
        case 0x1100 ... 0x115F, 0x2E80 ... 0x303E, 0x3041 ... 0x33FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF,
             0xA000 ... 0xA4CF, 0xAC00 ... 0xD7A3, 0xF900 ... 0xFAFF, 0xFE30 ... 0xFE4F, 0xFF00 ... 0xFF60,
             0xFFE0 ... 0xFFE6, 0x20000 ... 0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
