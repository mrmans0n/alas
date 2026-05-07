import SwiftUI

/// Renders `text` with characters at `indices` highlighted. The highlight
/// color is `mod` (slightly muted vs. design's brighter variant — close
/// enough for v1 without per-theme JSON edits).
///
/// Indices are grapheme-cluster positions, matching what `FuzzyMatch`
/// produces via `Array(target).enumerated()`.
struct Highlighted: View {
    let text: String
    let indices: [Int]
    @Environment(\.theme) private var theme

    var body: some View {
        let set = Set(indices)
        var attributed = AttributedString(text)
        for (i, _) in text.enumerated() where set.contains(i) {
            let start = attributed.index(attributed.startIndex, offsetByCharacters: i)
            let end   = attributed.index(start, offsetByCharacters: 1)
            attributed[start..<end].foregroundColor = theme.color("mod")
            attributed[start..<end].font = .system(
                size: NSFont.systemFontSize,
                weight: .heavy,
                design: .monospaced
            )
        }
        return Text(attributed)
    }
}
