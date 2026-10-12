import AppKit
import SwiftUI

/// Row metrics shared by every merge pane. Scroll sync, ribbons, and band
/// drawing all compute positions as `inset + row * rowHeight`, so the panes
/// must lay out every line at exactly the same height.
struct MergePaneMetrics: Equatable {
    static let contentInset = NSSize(width: 6, height: 6)

    let font: NSFont
    let rowHeight: CGFloat
    let baselineOffset: CGFloat

    init(fontFamily: String, fontSize: CGFloat) {
        font = CenterTypography.resolveCodeFont(family: fontFamily, size: fontSize)
        let natural = font.ascender - font.descender + font.leading
        rowHeight = ceil(natural * CenterTypography.lineHeightMultiple)
        baselineOffset = floor((rowHeight - natural) / 2)
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight
        style.maximumLineHeight = rowHeight
        return style
    }

    func baseAttributes(foreground: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: foreground,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: baselineOffset,
        ]
    }

    func rowTop(_ row: Int) -> CGFloat {
        Self.contentInset.height + CGFloat(row) * rowHeight
    }
}

/// Hunk colors resolved from the app theme. LOCAL and REMOTE keep the same
/// hue in their side pane, the ribbons, and the stacked RESULT hunk.
struct MergePalette: Equatable {
    let local: NSColor
    let remote: NSColor
    let base: NSColor
    let background: NSColor
    let gutterBackground: NSColor
    let lineNumber: NSColor

    init(theme: Theme) {
        let editor = EditorTheme(theme: theme)
        local = NSColor(theme.color("add"))
        remote = NSColor(theme.color("info"))
        base = NSColor(theme.color("fg-dim"))
        background = editor.bg
        gutterBackground = editor.bg
        lineNumber = editor.gutterFG
    }

    func color(for kind: MergeBand.Kind) -> NSColor {
        switch kind {
        case .local: local
        case .remote: remote
        case .base: base
        }
    }

    func fill(for kind: MergeBand.Kind, isCurrent: Bool) -> NSColor {
        color(for: kind).withAlphaComponent(isCurrent ? 0.17 : 0.08)
    }

    func border(for kind: MergeBand.Kind, isCurrent: Bool) -> NSColor {
        color(for: kind).withAlphaComponent(isCurrent ? 0.85 : 0.35)
    }

    func wordHighlight(for kind: MergeBand.Kind) -> NSColor {
        color(for: kind).withAlphaComponent(0.30)
    }
}

/// A run of rows drawn as one full-width tinted block with hairline borders.
/// An empty `rows` range marks where a side has no lines (a pure deletion)
/// and is drawn as a single insertion line.
struct MergeBand: Equatable {
    enum Kind: Equatable {
        case local, base, remote
    }

    let rows: Range<Int>
    let kind: Kind
    let isCurrent: Bool
}

/// Draws a list of bands in a flipped coordinate space. Shared by the text
/// views and the line-number rulers so a hunk reads as one block across both.
enum MergeBandPainter {
    static func draw(
        _ bands: [MergeBand],
        palette: MergePalette,
        rowTop: (Int) -> CGFloat,
        rowHeight: CGFloat,
        minX: CGFloat,
        maxX: CGFloat,
        dirtyRect: NSRect,
        accentBar: Bool
    ) {
        for band in bands {
            let top = rowTop(band.rows.lowerBound)
            let height = CGFloat(band.rows.count) * rowHeight
            guard top - 2 <= dirtyRect.maxY, top + height + 2 >= dirtyRect.minY else { continue }
            let border = palette.border(for: band.kind, isCurrent: band.isCurrent)
            if band.rows.isEmpty {
                border.setFill()
                NSRect(x: minX, y: top - 1, width: maxX - minX, height: 2).fill()
                continue
            }
            palette.fill(for: band.kind, isCurrent: band.isCurrent).setFill()
            NSRect(x: minX, y: top, width: maxX - minX, height: height).fill(using: .sourceOver)
            border.setFill()
            NSRect(x: minX, y: top, width: maxX - minX, height: 1).fill(using: .sourceOver)
            NSRect(x: minX, y: top + height - 1, width: maxX - minX, height: 1).fill(using: .sourceOver)
            if accentBar {
                palette.color(for: band.kind)
                    .withAlphaComponent(band.isCurrent ? 0.95 : 0.55)
                    .setFill()
                NSRect(x: minX, y: top, width: 3, height: height).fill(using: .sourceOver)
            }
        }
    }
}

/// Text view used by all three merge panes. Uses TextKit 1 so line
/// fragments honor the fixed row height exactly, and paints hunk bands
/// across the full width behind the text (attributed background colors
/// only cover glyphs, which left ragged tints).
@MainActor
final class MergeCodeTextView: NSTextView {
    var bands: [MergeBand] = [] {
        didSet { if bands != oldValue { needsDisplay = true } }
    }
    var palette: MergePalette? {
        didSet { if palette != oldValue { needsDisplay = true } }
    }
    var rowHeight: CGFloat = 16 {
        didSet { if rowHeight != oldValue { needsDisplay = true } }
    }

    static func make(editable: Bool) -> MergeCodeTextView {
        let textView = MergeCodeTextView(usingTextLayoutManager: false)
        textView.isEditable = editable
        textView.isSelectable = true
        textView.allowsUndo = editable
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.drawsBackground = true
        textView.textContainerInset = MergePaneMetrics.contentInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        return textView
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let palette, !bands.isEmpty else { return }
        let rowHeight = rowHeight
        MergeBandPainter.draw(
            bands,
            palette: palette,
            rowTop: { MergePaneMetrics.contentInset.height + CGFloat($0) * rowHeight },
            rowHeight: rowHeight,
            minX: bounds.minX,
            maxX: bounds.maxX,
            dirtyRect: rect,
            accentBar: false
        )
    }
}

/// Per-row syntax and word-diff overlays for one pane's text.
enum MergePaneText {
    struct WordMark: Equatable {
        let ranges: [NSRange]
        let kind: MergeBand.Kind
    }

    struct Rendered: Equatable {
        let text: String
        let rowRanges: [NSRange]
    }

    static func render(rows: [MergeRegionVisualLayout.VisualRow], endsWithNewline: Bool) -> Rendered {
        var text = ""
        var rowRanges: [NSRange] = []
        rowRanges.reserveCapacity(rows.count)
        var location = 0
        for (index, row) in rows.enumerated() {
            let isLastRow = index == rows.count - 1
            let suffix = (isLastRow && !endsWithNewline) ? "" : "\n"
            let piece = row.content + suffix
            let length = (piece as NSString).length
            text += piece
            rowRanges.append(NSRange(location: location, length: length))
            location += length
        }
        return Rendered(text: text, rowRanges: rowRanges)
    }

    static func attributedString(
        rendered: Rendered,
        lineSpans: [[MergeSyntaxHighlighter.LineSpan]],
        wordMarks: [Int: WordMark],
        metrics: MergePaneMetrics,
        theme: Theme,
        palette: MergePalette
    ) -> NSMutableAttributedString {
        let editorTheme = EditorTheme(theme: theme)
        let result = NSMutableAttributedString(
            string: rendered.text,
            attributes: metrics.baseAttributes(foreground: editorTheme.defaultFG)
        )
        for (row, range) in rendered.rowRanges.enumerated() {
            let contentLength = max(0, range.length - 1)
            if row < lineSpans.count {
                for span in lineSpans[row] where span.location + span.length <= range.length {
                    result.addAttribute(
                        .foregroundColor,
                        value: editorTheme.color(for: span.capture),
                        range: NSRange(location: range.location + span.location, length: span.length)
                    )
                }
            }
            if let mark = wordMarks[row] {
                let color = palette.wordHighlight(for: mark.kind)
                for word in mark.ranges where NSMaxRange(word) <= max(contentLength, range.length) {
                    result.addAttribute(
                        .backgroundColor,
                        value: color,
                        range: NSRange(location: range.location + word.location, length: word.length)
                    )
                }
            }
        }
        return result
    }

    /// Copies attributes onto storage whose text already matches, keeping
    /// the selection, undo stack, and scroll position intact.
    static func applyAttributes(_ attributed: NSAttributedString, to storage: NSTextStorage) {
        guard storage.string == attributed.string else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        attributed.enumerateAttributes(in: fullRange) { attrs, range, _ in
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()
    }
}
