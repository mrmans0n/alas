import AppKit
import CoreText

/// Markdown laid out as positioned CoreText lines and block backgrounds, with
/// the spacing `ACPMarkdownText` gives its SwiftUI blocks. Pure geometry: a row
/// view draws `lines` and `backgrounds` and owns no layout of its own.
@MainActor
struct ACPTranscriptMarkdownLayout {
    struct Line {
        let line: CTLine
        /// Top-left of the line's box, in a flipped space.
        var origin: CGPoint
        var height: CGFloat
        /// Underlined runs, which `CTLineDraw` leaves undrawn.
        var underlines: [Underline] = []
        /// The index into `texts` of the block this line shows, or nil for
        /// drawn-only text such as a code block's language label.
        var block: Int?
        /// The line's range in its block's text, including the whitespace
        /// it hangs past its end.
        var range = NSRange(location: 0, length: 0)
        /// How much of `range` the line draws, without that whitespace.
        var visibleLength = 0
        /// The right edge of the box the line was broken into.
        var maxX: CGFloat = 0
    }

    /// A table's grid: its frame, the x of each column divider, and the
    /// bottom of each row (header first).
    struct Table {
        let rect: CGRect
        let columnXs: [CGFloat]
        let rowBottoms: [CGFloat]
        /// The indices into `texts` of its cells, row-major.
        let blocks: Range<Int>
        let fill: NSColor
        let headerFill: NSColor
        let headerRule: NSColor
        let divider: NSColor
        /// A hairline around the whole grid, so it reads as an object on the page.
        let border: NSColor
        let cornerRadius: CGFloat
    }

    /// A code block's "Copy" button in its header.
    struct CodeBlock {
        let code: String
        /// The language label as drawn in the header, and where.
        var label: (text: String, rect: CGRect)?
        /// The button's right edge, top, and height; its width follows its label.
        let maxX: CGFloat
        let minY: CGFloat
        let height: CGFloat
    }

    /// The "Copy" and "Copied" labels and colors every code block's button shares.
    struct CopyButtonStyle {
        let copy: CTLine
        let copied: CTLine
        let copyIcon: NSImage
        let copiedIcon: NSImage
        let ascent: CGFloat
        let fill: NSColor
        let copiedFill: NSColor

        /// The button's width: icon, spacing, and label inside its padding.
        @MainActor func width(copied: Bool) -> CGFloat {
            let label = copied ? self.copied : copy
            let icon = copied ? copiedIcon : copyIcon
            return ceil(icon.size.width + ACPTranscriptMarkdownLayout.copyButtonIconSpacing
                + CGFloat(CTLineGetTypographicBounds(label, nil, nil, nil)))
                + 2 * ACPTranscriptMarkdownLayout.copyButtonHorizontalPadding
        }
    }

    /// A rule under one run, relative to its line's origin and baseline.
    struct Underline {
        let minX: CGFloat
        let width: CGFloat
        /// Distance below the baseline to the rule's top edge.
        let offset: CGFloat
        let thickness: CGFloat
        let color: NSColor
    }

    struct Background {
        let rect: CGRect
        let color: NSColor
        let cornerRadius: CGFloat
        /// A code block's header band: its height from the top, fill, and bottom divider.
        var header: (height: CGFloat, fill: NSColor, divider: NSColor)?
        /// A hairline around the block, drawn inside its rect.
        var border: NSColor?
    }

    // Copied from `ACPMarkdownText` and its `CodeBlockView`. These are steps of
    // `DesignScale.space`, the same in both densities; values that differ by
    // density come from the `scale` passed to `make`.
    static let h1TopPadding: CGFloat = 4
    static let headingTopPadding: CGFloat = 2
    static let quoteBarWidth: CGFloat = 2
    static let quoteBarGap: CGFloat = 10
    static let quoteBarAlpha: CGFloat = 0.55
    static let codeBackgroundAlpha: CGFloat = 0.6
    static let codeBodyHorizontalPadding: CGFloat = 12
    static let codeBodyVerticalPadding: CGFloat = 8
    static let codeHeaderHorizontalPadding: CGFloat = 12
    /// Between the language label and the Copy button.
    static let codeHeaderSpacing: CGFloat = 8
    static let codeHeaderVerticalPadding: CGFloat = 4
    /// Height of the empty header `CodeBlockView` keeps when there is no language.
    static let codeEmptyHeaderContentHeight: CGFloat = 1
    static let codeLineSpacing: CGFloat = 2
    static let codeLabelTracking: CGFloat = 0.4
    static let copyButtonHorizontalPadding: CGFloat = 4
    static let copyButtonIconSpacing: CGFloat = 4
    static let copyButtonVerticalPadding: CGFloat = 2
    static let copyButtonCornerRadius: CGFloat = 4
    // Copied from `ACPMarkdownText.tableView` and `tableRow`.
    static let maxNativeTableColumns = 5
    static let tableCellHorizontalPadding: CGFloat = 12
    static let tableCellVerticalPadding: CGFloat = 8
    static let tableDividerWidth: CGFloat = 0.5
    /// How tall SwiftUI sizes an empty `Text`, whatever its font.
    static let emptyTextHeight: CGFloat = 14

    /// How wide prose runs.
    let width: CGFloat
    /// How wide code blocks and tables run: `width`, or more in a transcript
    /// row that breaks out of the reading column.
    let wideWidth: CGFloat
    let height: CGFloat
    let lines: [Line]
    let backgrounds: [Background]
    /// The selectable text of each block, in order: rendered inline markdown
    /// (no backticks or asterisks) and code bodies.
    let texts: [String]
    /// Each block's rendered text with its attributes, for link boundaries.
    let attributedTexts: [NSAttributedString]
    let codeBlocks: [CodeBlock]
    let copyButtonStyle: CopyButtonStyle
    let tables: [Table]
    /// The separator copied after each block in `texts`: `"\t"` between the
    /// cells of a table row, `"\n"` otherwise.
    let blockSeparators: [String]
    /// The tallest line, so a vertical lookup can search on line tops alone.
    let maxLineHeight: CGFloat

    /// Whether every block can be drawn here. Images, Mermaid diagrams and
    /// task lists need views of their own, and so do tables of more than
    /// `maxNativeTableColumns` columns. So does prose with an inline image:
    /// the SwiftUI renderer turns it into a text attachment that `CTLineDraw`
    /// cannot show. `![` is a conservative stand-in for the inline renderer's
    /// image matching, which needs a theme.
    static func supports(_ blocks: [ACPMarkdownParser.Block]) -> Bool {
        blocks.allSatisfy { block in
            switch block {
            case .image, .mermaid, .taskList: false
            case .table(let header, let rows):
                max(header.count, rows.map(\.count).max() ?? 0) <= maxNativeTableColumns
                    && !(header + rows.flatMap { $0 }).contains { $0.contains("![") }
            case .heading(_, let text), .paragraph(let text), .quote(let text): !text.contains("![")
            case .code, .streamingCode: true
            }
        }
    }

    static func make(
        source: String, width: CGFloat, wideWidth: CGFloat? = nil, theme: Theme, typography: ACPChatTypography,
        scale: DesignScale = .comfortable
    ) -> ACPTranscriptMarkdownLayout? {
        let blocks = ACPMarkdownParser.parse(source)
        guard supports(blocks) else { return nil }
        let wideWidth = max(1, wideWidth ?? width)
        var builder = Builder(width: max(1, width), wideWidth: wideWidth, theme: theme, typography: typography, scale: scale)
        for (index, block) in blocks.enumerated() {
            if index > 0 { builder.y += scale.transcriptBlockSpacing }
            builder.add(block)
        }
        return ACPTranscriptMarkdownLayout(
            width: max(1, width), wideWidth: wideWidth, height: builder.y, lines: builder.lines, backgrounds: builder.backgrounds,
            texts: builder.texts, attributedTexts: builder.attributedTexts, codeBlocks: builder.codeBlocks,
            copyButtonStyle: builder.copyButtonStyle, tables: builder.tables, blockSeparators: builder.blockSeparators,
            maxLineHeight: builder.lines.map(\.height).max() ?? 0
        )
    }

    /// What a table column's cells need, padding included.
    struct TableColumn: Equatable {
        /// Its longest word, so no word has to break unless the table can't fit.
        var minWidth: CGFloat
        /// Its longest cell on one line.
        var idealWidth: CGFloat
        var isNumeric: Bool
    }

    /// A cell's longest word counts for at most this, so one long path or URL
    /// doesn't squeeze the other columns.
    private static let tableWordWidthLimit: CGFloat = 160

    /// Measured from the same attributed strings both table paths draw, so the
    /// native and SwiftUI rows break their cells alike. `render` gives the cell at
    /// a row (the header is 0) and column. Cached because a table still streaming
    /// through SwiftUI asks on every body.
    static func tableColumns(
        header: [String], rows: [[String]], typography: ACPChatTypography,
        render: (_ row: Int, _ column: Int, _ source: String) -> NSAttributedString
    ) -> [TableColumn] {
        // Hashes the cells rather than joining them into one string per body.
        let key = TableColumnsKey(fontFamily: typography.fontFamily, size: typography.paragraphSize, header: header, rows: rows)
        if let cached = tableColumnCache.object(forKey: key) { return cached.columns }
        let count = max(header.count, rows.map(\.count).max() ?? 0)
        let columns = (0..<count).map { column -> TableColumn in
            var result = TableColumn(minWidth: 0, idealWidth: 0, isNumeric: false)
            for (rowIndex, cells) in ([header] + rows).enumerated() where column < cells.count {
                let (ideal, word) = measuredWidths(of: render(rowIndex, column, cells[column]))
                result.idealWidth = max(result.idealWidth, ideal)
                result.minWidth = max(result.minWidth, word)
            }
            let padding = 2 * tableCellHorizontalPadding
            result.idealWidth += padding
            result.minWidth = min(min(result.minWidth, tableWordWidthLimit) + padding, result.idealWidth)
            result.isNumeric = isNumericColumn(rows.map { column < $0.count ? $0[column] : "" })
            return result
        }
        tableColumnCache.setObject(TableColumnsBox(columns), forKey: key)
        return columns
    }

    private final class TableColumnsBox {
        let columns: [TableColumn]
        init(_ columns: [TableColumn]) { self.columns = columns }
    }

    /// `NSCache` wants an object key; equality compares every cell, so a
    /// hash collision can never hand back another table's columns.
    private final class TableColumnsKey: NSObject {
        let fontFamily: String
        let size: CGFloat
        let header: [String]
        let rows: [[String]]
        private let hashValueCache: Int

        init(fontFamily: String, size: CGFloat, header: [String], rows: [[String]]) {
            self.fontFamily = fontFamily
            self.size = size
            self.header = header
            self.rows = rows
            var hasher = Hasher()
            hasher.combine(fontFamily)
            hasher.combine(size)
            hasher.combine(header)
            hasher.combine(rows)
            hashValueCache = hasher.finalize()
        }

        override var hash: Int { hashValueCache }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? TableColumnsKey else { return false }
            return hashValueCache == other.hashValueCache && size == other.size && fontFamily == other.fontFamily
                && header == other.header && rows == other.rows
        }
    }

    private static let tableColumnCache: NSCache<TableColumnsKey, TableColumnsBox> = {
        let cache = NSCache<TableColumnsKey, TableColumnsBox>()
        cache.countLimit = 256
        return cache
    }()

    /// A cell's width on one line and its longest space-separated word's, one
    /// point over so what exactly fits doesn't wrap on rounding. Offsets into one
    /// line, because this runs for every cell of a table as it first scrolls in.
    private static func measuredWidths(of text: NSAttributedString) -> (ideal: CGFloat, word: CGFloat) {
        let line = CTLineCreateWithAttributedString(text)
        let ideal = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))) + 1
        let utf16 = text.string.utf16
        guard utf16.contains(32) else { return (ideal, ideal) }
        var word: CGFloat = 0
        var start = 0
        func close(at end: Int) {
            guard end > start else { return }
            let width = CTLineGetOffsetForStringIndex(line, end, nil) - CTLineGetOffsetForStringIndex(line, start, nil)
            word = max(word, ceil(width) + 1)
        }
        for (index, unit) in utf16.enumerated() where unit == 32 {
            close(at: index)
            start = index + 1
        }
        close(at: utf16.count)
        return (ideal, word)
    }

    /// Fits the columns to `available`. Columns that fit on one line get the
    /// room left over, prose first, so numbers stay close together. Otherwise
    /// each column gets its longest word and a share of the rest by how much it
    /// wants. A table that can't fit even that shrinks those widths to
    /// `available`. Both rendering paths use this, so a table keeps its shape
    /// when a finished message moves from SwiftUI to a native row.
    static func tableColumnWidths(_ columns: [TableColumn], available: CGFloat) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let room = available - tableDividerWidth * CGFloat(columns.count - 1)
        let totalIdeal = columns.reduce(0) { $0 + $1.idealWidth }
        let totalMin = columns.reduce(0) { $0 + $1.minWidth }
        if totalIdeal <= room {
            let prose = columns.contains { !$0.isNumeric }
            let growing = columns.filter { !prose || !$0.isNumeric }.reduce(0) { $0 + $1.idealWidth }
            return columns.map { column in
                guard !prose || !column.isNumeric else { return column.idealWidth }
                return column.idealWidth + (room - totalIdeal) * column.idealWidth / growing
            }
        }
        if totalMin < room {
            let share = (room - totalMin) / (totalIdeal - totalMin)
            return columns.map { $0.minWidth + ($0.idealWidth - $0.minWidth) * share }
        }
        return columns.map { max(1, $0.minWidth * room / totalMin) }
    }

    /// Whether a column's cells are all numbers, units allowed: "1,240", "2.1 s",
    /// "$12", "−3%". Blank cells don't count either way; a column of them is not numeric.
    nonisolated static func isNumericColumn(_ cells: [String]) -> Bool {
        var sawNumber = false
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`")))
            if trimmed.isEmpty || trimmed == "-" || trimmed == "—" { continue }
            guard trimmed.wholeMatch(of: numericCellPattern) != nil else { return false }
            sawNumber = true
        }
        return sawNumber
    }

    private nonisolated(unsafe) static let numericCellPattern = /[~≈+\-−±$€£]?[0-9][0-9,._]*\s?(%|[A-Za-zµ]{1,3})?/

    /// A line of `font` as SwiftUI sizes it: ascent to the nearest point, descent
    /// and leading rounded up. Measured against `Text`: at half-point sizes such
    /// as 12.5 the ascent lands just past a whole point and is not rounded up.
    private static func swiftUILineHeight(of font: NSFont) -> CGFloat {
        font.ascender.rounded() + ceil(-font.descender) + ceil(font.leading)
    }

    /// Inside the Copy button's padding, here and in `CodeBlockView`, which pins
    /// it: the height of SwiftUI's symbol image changes with the point size in
    /// ways `NSImage` does not report, and half-point chat sizes hit that.
    static func copyButtonContentHeight(_ typography: ACPChatTypography) -> CGFloat {
        let label = swiftUILineHeight(of: .systemFont(ofSize: typography.labelSize, weight: .medium))
        let icon = swiftUILineHeight(of: .systemFont(ofSize: typography.labelSize, weight: .regular)) + 2
        return max(label, icon)
    }

    /// Code block `index`'s "Copy" button, sized for the label it shows.
    func copyButtonRect(_ index: Int, copied: Bool) -> CGRect {
        let block = codeBlocks[index]
        let width = copyButtonStyle.width(copied: copied)
        return CGRect(x: block.maxX - width, y: block.minY, width: width, height: block.height)
    }

    /// The table whose cell shows `block`, if any.
    func table(containing block: Int) -> Table? {
        tables.first { $0.blocks.contains(block) }
    }

    /// The lines whose boxes overlap `rect` vertically, including ones it only cuts.
    func linesIntersecting(_ rect: CGRect) -> ArraySlice<Line> {
        // Lines are sorted by top, but a table's cells share a row, so bottoms
        // are not monotonic; search on tops and the tallest line instead.
        // Callers re-check each line, so a few extra at the top edge are harmless.
        let first = partitionPoint { $0.origin.y + maxLineHeight <= rect.minY }
        let last = partitionPoint { $0.origin.y < rect.maxY }
        return first < last ? lines[first..<last] : lines[first..<first]
    }

    /// A link as drawn: its URL, visible text, and the rect of each line it
    /// covers, in layout coordinates. A wrapped link has one rect per line.
    struct LinkSpan {
        let url: URL
        let text: String
        let rects: [CGRect]
        /// The block and source offset where the span ends, so only the
        /// next run of the same link continues it.
        let block: Int
        let end: Int
    }

    /// Every link in drawing order. Computed on demand (accessibility asks),
    /// so laying out a row pays nothing for it.
    func linkSpans() -> [LinkSpan] {
        var spans: [LinkSpan] = []
        for line in lines {
            guard let block = line.block, texts.indices.contains(block) else { continue }
            let blockText = texts[block] as NSString
            // Source order, so a right-to-left link's runs, drawn in reverse, still join.
            let runs = (CTLineGetGlyphRuns(line.line) as! [CTRun]).sorted { CTRunGetStringRange($0).location < CTRunGetStringRange($1).location }
            for run in runs {
                let value = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.link]
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { continue }
                let range = CTRunGetStringRange(run)
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
                let rect = CGRect(x: line.origin.x + position.x, y: line.origin.y, width: width, height: line.height)
                let text = NSMaxRange(NSRange(location: range.location, length: range.length)) <= blockText.length
                    ? blockText.substring(with: NSRange(location: range.location, length: range.length)) : ""
                let end = range.location + range.length
                // Runs of one link continue across style changes and line wraps:
                // same URL, same block, and nothing but wrapped-away whitespace
                // between them in the source. Two links to one URL stay apart.
                // Lines run in y order, so a table cell's link can wrap past a
                // link in the next cell; continue the block's latest span.
                if let lastIndex = spans.lastIndex(where: { $0.block == block }), case let last = spans[lastIndex],
                   last.url == url, last.end <= range.location,
                   Self.isSameLink(in: attributedTexts[block], endingAt: last.end, startingAt: range.location) {
                    let gap = blockText.substring(with: NSRange(location: last.end, length: range.location - last.end))
                    spans[lastIndex] = LinkSpan(
                        url: url, text: last.text + gap + text, rects: last.rects + [rect], block: block, end: end
                    )
                } else {
                    spans.append(LinkSpan(url: url, text: text, rects: [rect], block: block, end: end))
                }
            }
        }
        return spans
    }

    /// Marks which source link each rendered link character came from.
    static let linkOrdinal = NSAttributedString.Key("alas.acp.nativeLinkOrdinal")

    /// Whether the runs ending at `end` and starting at `start` belong to one
    /// source link (a wrap or a style change inside it), not two links.
    private static func isSameLink(in text: NSAttributedString, endingAt end: Int, startingAt start: Int) -> Bool {
        guard end > 0, end <= start, start < text.length else { return false }
        let before = text.attribute(linkOrdinal, at: end - 1, effectiveRange: nil) as? Int
        let after = text.attribute(linkOrdinal, at: start, effectiveRange: nil) as? Int
        return before != nil && before == after
    }

    /// The line under `point`, in layout coordinates: of the lines whose box
    /// holds `point.y` (a table row's cells share one band), the one whose
    /// `origin.x..<maxX` holds `point.x`, else the nearest in x. Only lines
    /// `isIncluded` accepts are considered.
    func line(at point: CGPoint, where isIncluded: (Line) -> Bool = { _ in true }) -> Line? {
        var nearest: (line: Line, distance: CGFloat)?
        for line in linesIntersecting(CGRect(x: point.x, y: point.y, width: 0, height: 0))
            where line.origin.y <= point.y && point.y < line.origin.y + line.height && isIncluded(line) {
            let distance = max(line.origin.x - point.x, point.x - line.maxX, 0)
            if distance == 0, point.x < line.maxX { return line }
            if nearest.map({ distance < $0.distance }) ?? true { nearest = (line, distance) }
        }
        return nearest?.line
    }

    /// The link under `point`, in layout coordinates; nil outside link glyphs.
    func link(at point: CGPoint) -> URL? {
        guard let line = line(at: point) else { return nil }
        let x = point.x - line.origin.x
        guard x >= 0, x < CGFloat(CTLineGetTypographicBounds(line.line, nil, nil, nil)) else { return nil }
        // The run's drawn extent, not a caret index: past a glyph's midpoint
        // the caret index is the next character, outside a link's last run.
        for run in CTLineGetGlyphRuns(line.line) as! [CTRun] where CTRunGetGlyphCount(run) > 0 {
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            guard x >= position.x, x < position.x + width else { continue }
            let value = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.link]
            return (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
        }
        return nil
    }

    /// The first index whose line fails `predicate`, which holds for a prefix.
    private func partitionPoint(_ predicate: (Line) -> Bool) -> Int {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(lines[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Building

    @MainActor
    private struct Builder {
        let width: CGFloat
        let wideWidth: CGFloat
        let theme: Theme
        let typography: ACPChatTypography
        let scale: DesignScale
        var y: CGFloat = 0
        var lines: [Line] = []
        var backgrounds: [Background] = []
        var texts: [String] = []
        var attributedTexts: [NSAttributedString] = []
        var codeBlocks: [CodeBlock] = []
        var tables: [Table] = []
        var blockSeparators: [String] = []
        let copyButtonStyle: CopyButtonStyle

        init(width: CGFloat, wideWidth: CGFloat, theme: Theme, typography: ACPChatTypography, scale: DesignScale) {
            self.width = width
            self.wideWidth = wideWidth
            self.theme = theme
            self.typography = typography
            self.scale = scale
            // As `CodeBlockView.copyButton`.
            let font = NSFont.systemFont(ofSize: typography.labelSize, weight: .medium)
            func label(_ string: String, _ color: NSColor) -> CTLine {
                CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
            }
            func icon(_ name: String, weight: NSFont.Weight, _ color: NSColor) -> NSImage {
                let configuration = NSImage.SymbolConfiguration(pointSize: typography.labelSize, weight: weight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
            }
            let add = theme.nsColor("add")
            let muted = theme.nsColor("fg-muted")
            copyButtonStyle = CopyButtonStyle(
                copy: label("Copy", muted),
                copied: label("Copied", add),
                copyIcon: icon("doc.on.doc", weight: .regular, muted),
                copiedIcon: icon("checkmark", weight: .bold, add),
                ascent: font.ascender,
                fill: theme.nsColor("bg-3").withAlphaComponent(0.6),
                copiedFill: theme.nsColor("bg-3").withAlphaComponent(0.4)
            )
        }

        mutating func add(_ block: ACPMarkdownParser.Block) {
            switch block {
            case .heading(let level, let text):
                y += level == 1 ? ACPTranscriptMarkdownLayout.h1TopPadding : ACPTranscriptMarkdownLayout.headingTopPadding
                let font = typography.appKitFont(size: typography.headingSize(level: level), traits: .boldFontMask)
                addBlockText(
                    inline(text, role: .heading(level: level)), x: 0, width: width,
                    lineHeight: ACPTranscriptMarkdownLayout.swiftUILineHeight(of: font)
                )
            case .paragraph(let text):
                addSpacedBlockText(inline(text, role: .body), x: 0, width: width, lineSpacing: scale.transcriptLineSpacing)
            case .quote(let text):
                let top = y
                let x = ACPTranscriptMarkdownLayout.quoteBarWidth + ACPTranscriptMarkdownLayout.quoteBarGap
                addSpacedBlockText(inline(text, role: .quote), x: x, width: max(1, width - x), lineSpacing: scale.transcriptLineSpacing)
                backgrounds.append(Background(
                    rect: CGRect(x: 0, y: top, width: ACPTranscriptMarkdownLayout.quoteBarWidth, height: y - top),
                    color: theme.nsColor("accent").withAlphaComponent(ACPTranscriptMarkdownLayout.quoteBarAlpha),
                    cornerRadius: 0 // design-literal: a quote bar is a plain rule
                ))
            case .code(let language, let body):
                addCode(language: language, body: body, highlighted: true)
            case .streamingCode(let language, let body):
                addCode(language: language, body: body, highlighted: false)
            case .table(let header, let rows):
                addTable(header: header, rows: rows)
            case .taskList, .image, .mermaid:
                break
            }
        }

        private func inline(_ text: String, role: ACPMarkdownInlineRole) -> NSAttributedString {
            let rendered = ACPMarkdownInlineRenderer.makeAttributedString(source: text, theme: theme, typography: typography, role: role)
            // As `ACPMarkdownInlineText.plainText` styles links for SwiftUI text.
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { link, range, _ in
                guard link != nil else { return }
                rendered.addAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            Self.markLinkBoundaries(in: rendered, source: text)
            return rendered
        }

        /// Equal `.link` values coalesce, so two links to one URL written back to
        /// back render as one range. Each source link gets its own ordinal so
        /// accessibility can tell them apart; a range whose labels don't add up
        /// stays one link.
        private static func markLinkBoundaries(in rendered: NSMutableAttributedString, source: String) {
            // Scan what the renderer parses, where bare URLs are already `<url>` autolinks.
            var sourceLinks = MarkdownLinkScanner.links(
                in: ACPBareURLLinkifier.markdownAutolinkingBareURLs(source, preserveFencedCodeBlocks: false)
            )
            var ordinal = 0
            rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
                guard let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) else { return }
                // The source links this range was rendered from, in order.
                // Source links before the first one to this URL didn't render as links and are skipped.
                // Candidates are consumed only when their lengths add up to the range.
                let matches = { (candidate: MarkdownLinkScanner.Link) in
                    URL(string: candidate.url)?.absoluteString == url.absoluteString || candidate.url == url.absoluteString
                }
                let start = sourceLinks.firstIndex(where: matches) ?? sourceLinks.endIndex
                var lengths: [Int] = []
                var total = 0
                for next in sourceLinks[start...] {
                    guard total < range.length, matches(next) else { break }
                    let length = next.isAutolink
                        ? (next.label as NSString).length
                        : (ACPMarkdownInlineRenderer.plainText(next.label) as NSString).length
                    lengths.append(length)
                    total += length
                }
                if total == range.length, !lengths.isEmpty {
                    sourceLinks.removeFirst(start + lengths.count)
                } else {
                    lengths = [range.length]
                }
                var location = range.location
                for length in lengths {
                    rendered.addAttribute(linkOrdinal, value: ordinal, range: NSRange(location: location, length: length))
                    ordinal += 1
                    location += length
                }
            }
        }

        private static func underlines(of line: CTLine) -> [Underline] {
            var result: [Underline] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let style = attributes[NSAttributedString.Key.underlineStyle] as? Int, style != 0,
                      let font = attributes[NSAttributedString.Key.font] as? NSFont
                else { continue }
                var position = CGPoint.zero
                CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                let thickness = max(1, font.underlineThickness)
                result.append(Underline(
                    minX: position.x,
                    width: CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)),
                    offset: -font.underlinePosition - thickness / 2,
                    thickness: thickness,
                    color: attributes[NSAttributedString.Key.foregroundColor] as? NSColor ?? .linkColor
                ))
            }
            return result
        }

        private mutating func addCode(language: String?, body: String, highlighted: Bool) {
            typealias L = ACPTranscriptMarkdownLayout
            let width = wideWidth
            let top = y
            // The background is added first so it paints under the lines.
            backgrounds.append(Background(rect: .zero, color: .clear, cornerRadius: 0)) // design-literal: placeholder, replaced below
            let backgroundIndex = backgrounds.count - 1

            // The header is as tall as the taller of its label and the button.
            let buttonHeight = L.copyButtonContentHeight(typography) + 2 * L.copyButtonVerticalPadding
            let headerContentHeight = buttonHeight
            y += L.codeHeaderVerticalPadding
            let headerTop = y
            var headerHeight = max(L.codeEmptyHeaderContentHeight, headerContentHeight)
            var labelRect: (text: String, rect: CGRect)?
            if let language, !language.isEmpty {
                let label = NSAttributedString(string: language.uppercased(), attributes: [
                    .font: typography.appKitFont(size: typography.labelSize, traits: .boldFontMask),
                    .foregroundColor: theme.nsColor("fg-dim"),
                    .kern: L.codeLabelTracking,
                ])
                let first = lines.count
                // As the SwiftUI header's `HStack`, the label gets what the Copy button and spacing
                // leave; the wider "Copied" label is reserved so the label never runs under it.
                let buttonWidth = max(copyButtonStyle.width(copied: false), copyButtonStyle.width(copied: true))
                let labelWidth = width - 2 * L.codeHeaderHorizontalPadding - buttonWidth - L.codeHeaderSpacing
                addText(label, x: L.codeHeaderHorizontalPadding, width: max(1, labelWidth), lineSpacing: 0)
                let labelHeight = y - headerTop
                headerHeight = max(labelHeight, headerContentHeight)
                for index in first..<lines.count {
                    lines[index].origin.y += (headerHeight - labelHeight) / 2
                }
                let rect = lines[first...].map { line in
                    CGRect(origin: line.origin, size: CGSize(width: CTLineGetTypographicBounds(line.line, nil, nil, nil), height: line.height))
                }.reduce(CGRect.null) { $0.union($1) }
                labelRect = (label.string, rect)
            }
            codeBlocks.append(CodeBlock(
                code: body, label: labelRect, maxX: width - L.codeHeaderHorizontalPadding,
                minY: headerTop + (headerHeight - buttonHeight) / 2, height: buttonHeight
            ))
            y = headerTop + headerHeight + L.codeHeaderVerticalPadding
            let headerBandHeight = y - top

            y += L.codeBodyVerticalPadding
            let code: NSAttributedString
            if highlighted {
                // As `ACPSyntaxHighlightedText`, so the colors match the SwiftUI block.
                code = HighlightCache.attributedString(code: body, language: language, theme: theme, typography: typography)
            } else {
                code = NSAttributedString(string: body, attributes: [
                    .font: CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize),
                    .foregroundColor: theme.nsColor("fg"),
                ])
            }
            // SwiftUI's line can be a point taller than TextKit's box.
            let codeFont = CenterTypography.resolveCodeFont(family: typography.fontFamily, size: typography.codeSize)
            addSpacedBlockText(
                code, x: L.codeBodyHorizontalPadding, width: max(1, width - 2 * L.codeBodyHorizontalPadding),
                lineSpacing: L.codeLineSpacing,
                lineHeight: L.swiftUILineHeight(of: codeFont),
                hangingIndent: scale.codeHangingIndent
            )
            y += L.codeBodyVerticalPadding

            backgrounds[backgroundIndex] = Background(
                rect: CGRect(x: 0, y: top, width: width, height: y - top),
                color: theme.nsColor("bg-0").withAlphaComponent(L.codeBackgroundAlpha),
                cornerRadius: scale.radius.medium,
                // As `CodeBlockView`'s header background and divider.
                header: (headerBandHeight, theme.nsColor("bg-2").withAlphaComponent(0.6), theme.nsColor("line-soft")),
                border: theme.nsColor("line-soft")
            )
        }

        private mutating func addTable(header: [String], rows: [[String]]) {
            typealias L = ACPTranscriptMarkdownLayout
            let width = wideWidth
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            guard columns > 0 else { return }
            let rendered = ([header] + rows).enumerated().map { rowIndex, cells in
                (0..<columns).map { inline($0 < cells.count ? cells[$0] : "", role: .tableCell(isHeader: rowIndex == 0)) }
            }
            let specs = L.tableColumns(header: header, rows: rows, typography: typography) { row, column, _ in rendered[row][column] }
            let columnWidths = L.tableColumnWidths(specs, available: width)
            var columnXs: [CGFloat] = [0]
            for columnWidth in columnWidths { columnXs.append(columnXs[columnXs.count - 1] + columnWidth + L.tableDividerWidth) }
            let top = y
            let firstLine = lines.count
            let firstBlock = texts.count
            var rowBottoms: [CGFloat] = []
            for rowIndex in rendered.indices {
                let rowTop = y
                var rowBottom = rowTop + 2 * L.tableCellVerticalPadding
                for column in 0..<columns {
                    y = rowTop + L.tableCellVerticalPadding
                    let x = columnXs[column] + L.tableCellHorizontalPadding
                    let cellWidth = max(1, columnWidths[column] - 2 * L.tableCellHorizontalPadding)
                    let role = ACPMarkdownInlineRole.tableCell(isHeader: rowIndex == 0)
                    let text = rendered[rowIndex][column]
                    let firstCellLine = lines.count
                    addBlockText(text, x: x, width: cellWidth, separator: column == columns - 1 ? "\n" : "\t")
                    if specs[column].isNumeric {
                        for index in firstCellLine..<lines.count {
                            let lineWidth = CGFloat(CTLineGetTypographicBounds(lines[index].line, nil, nil, nil))
                            lines[index].origin.x += max(0, cellWidth - lineWidth)
                        }
                    }
                    if text.length == 0 {
                        // An empty cell's `Text` still takes up a line in the SwiftUI table.
                        addEmptyLine(
                            attributes: inline("x", role: role).attributes(at: 0, effectiveRange: nil), at: 0, x: x, width: cellWidth,
                            lineHeight: L.emptyTextHeight, block: texts.count - 1
                        )
                    }
                    rowBottom = max(rowBottom, y + L.tableCellVerticalPadding)
                }
                rowBottoms.append(rowBottom)
                // A 0.5 pt rule follows every row but the last, as the SwiftUI table's dividers do.
                y = rowBottom + (rowIndex < rows.count ? L.tableDividerWidth : 0)
            }
            // Cells of one row share a y range; keep `lines` in y order (then x) so vertical lookups stay valid.
            lines[firstLine...].sort { ($0.origin.y, $0.origin.x) < ($1.origin.y, $1.origin.x) }
            tables.append(Table(
                // Columns fill the width exactly, as the SwiftUI table's background does.
                rect: CGRect(x: 0, y: top, width: width, height: y - top),
                columnXs: (1..<columns).map { columnXs[$0] - L.tableDividerWidth },
                rowBottoms: rowBottoms,
                blocks: firstBlock..<texts.count,
                fill: theme.nsColor("bg-0").withAlphaComponent(0.6),
                headerFill: theme.nsColor("bg-2").withAlphaComponent(0.5),
                headerRule: theme.nsColor("line"),
                divider: theme.nsColor("line-soft"),
                border: theme.nsColor("line-soft"),
                cornerRadius: scale.radius.medium
            ))
        }

        /// Adds a selectable block: its lines map back into `texts`, and
        /// `separator` follows it when the text is copied.
        private mutating func addBlockText(
            _ text: NSAttributedString, x: CGFloat, width: CGFloat, lineSpacing: CGFloat = 0, lineHeight: CGFloat? = nil,
            hangingIndent: CGFloat = 0, separator: String = "\n"
        ) {
            texts.append(text.string)
            attributedTexts.append(text)
            blockSeparators.append(separator)
            addText(
                text, x: x, width: width, lineSpacing: lineSpacing, lineHeight: lineHeight, hangingIndent: hangingIndent,
                block: texts.count - 1
            )
        }

        /// A selectable block with `lineSpacing` between its lines, not after the last one.
        private mutating func addSpacedBlockText(
            _ text: NSAttributedString, x: CGFloat, width: CGFloat, lineSpacing: CGFloat, lineHeight: CGFloat? = nil,
            hangingIndent: CGFloat = 0
        ) {
            let first = lines.count
            addBlockText(text, x: x, width: width, lineSpacing: lineSpacing, lineHeight: lineHeight, hangingIndent: hangingIndent)
            if lines.count > first {
                lines[lines.count - 1].height -= lineSpacing
                y -= lineSpacing
            }
        }

        /// Breaks `text` to `width` and stacks its lines from the current `y`.
        ///
        /// With a `hangingIndent`, every line breaks `hangingIndent` short of
        /// `width`, and a line that continues a wrapped one starts that far in.
        /// SwiftUI text has no hanging indent, so `CodeBlockView` narrows its
        /// `Text` by the indent instead, and the two break alike.
        private mutating func addText(
            _ text: NSAttributedString, x: CGFloat, width: CGFloat, lineSpacing: CGFloat = 0, lineHeight: CGFloat? = nil,
            hangingIndent: CGFloat = 0, block: Int? = nil
        ) {
            guard text.length > 0 else { return }
            let string = text.string as NSString
            let breakWidth = max(1, width - hangingIndent)
            let typesetter = CTTypesetterCreateWithAttributedString(text)
            // A final newline ends the line before it, so the blank line after it gets a pass of its own.
            let endsInNewline = text.string.last?.isNewline == true
            var start = 0
            while start < text.length || (start == text.length && endsInNewline) {
                guard start < text.length else {
                    addEmptyLine(
                        attributes: text.attributes(at: text.length - 1, effectiveRange: nil), at: start, x: x, width: width,
                        lineSpacing: lineSpacing, lineHeight: lineHeight, block: block
                    )
                    break
                }
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(breakWidth)))
                let continues = hangingIndent > 0 && start > 0 && string.character(at: start - 1) != 0x0A // "\n"
                let lineX = continues ? x + hangingIndent : x
                // Trailing whitespace hangs past the width; the drawn line leaves it off.
                let visible = Self.lengthWithoutTrailingWhitespace(string, from: start, count: count)
                // A zero-length range means "to the end of the string", so a blank
                // line gets an empty line of its own instead.
                let line = visible > 0
                    ? CTTypesetterCreateLine(typesetter, CFRange(location: start, length: visible))
                    : CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: text.attributes(at: start, effectiveRange: nil)))
                // A fallback font (emoji, CJK) can be taller than any `.font` attribute, and a
                // range without one measures 0; the line's own bounds are the floor.
                var ascent: CGFloat = 0, descent: CGFloat = 0
                CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                let measured = max(lineHeight ?? Self.lineHeight(of: text, range: NSRange(location: start, length: count)), ascent + descent)
                let height = (measured > 0 ? measured : typography.paragraphSize) + lineSpacing
                lines.append(Line(
                    line: line, origin: CGPoint(x: lineX, y: y), height: height, underlines: Self.underlines(of: line),
                    block: block, range: NSRange(location: start, length: count), visibleLength: visible, maxX: x + width
                ))
                y += height
                start += count
            }
        }

        /// Stacks an empty line, as tall as a line in `attributes`' font, at
        /// offset `location` of `block`.
        private mutating func addEmptyLine(
            attributes: [NSAttributedString.Key: Any], at location: Int, x: CGFloat, width: CGFloat,
            lineSpacing: CGFloat = 0, lineHeight: CGFloat? = nil, block: Int?
        ) {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let fontHeight = (attributes[.font] as? NSFont).map(ACPTranscriptMarkdownLayout.swiftUILineHeight(of:)) ?? 0
            let measured = max(lineHeight ?? fontHeight, ascent + descent)
            lines.append(Line(
                line: line, origin: CGPoint(x: x, y: y), height: (measured > 0 ? measured : typography.paragraphSize) + lineSpacing,
                block: block, range: NSRange(location: location, length: 0), visibleLength: 0, maxX: x + width
            ))
            y += lines[lines.count - 1].height
        }

        private static func lengthWithoutTrailingWhitespace(_ string: NSString, from start: Int, count: Int) -> Int {
            var end = start + count
            while end > start, let scalar = Unicode.Scalar(string.character(at: end - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                end -= 1
            }
            return end - start
        }

        /// The tallest line SwiftUI gives any font in `range`: TextKit leaves
        /// some sizes fractional, where SwiftUI rounds.
        private static func lineHeight(of text: NSAttributedString, range: NSRange) -> CGFloat {
            var height: CGFloat = 0
            text.enumerateAttribute(.font, in: range) { value, _, _ in
                if let font = value as? NSFont { height = max(height, ACPTranscriptMarkdownLayout.swiftUILineHeight(of: font)) }
            }
            return height
        }
    }
}

/// Highlighted code by content, language, theme and font, so a width change
/// re-breaks lines without highlighting again. Entries are immutable copies.
@MainActor
private enum HighlightCache {
    private static let cache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        // Long histories hold many unique blocks; keep the cache bounded.
        cache.countLimit = 256
        cache.totalCostLimit = 16 << 20
        return cache
    }()

    static func attributedString(
        code: String, language: String?, theme: Theme, typography: ACPChatTypography
    ) -> NSAttributedString {
        let resolved = language.flatMap(ACPCodeLanguage.highlighterExtension(for:))
        let key = [
            ACPSyntaxHighlightCacheKey.themeKey(theme), resolved ?? "", typography.fontFamily,
            "\(typography.codeSize)", code,
        ].joined(separator: "\u{0}") as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let highlighted = ACPCodeBlockHighlighter.attributedString(
            code: code, language: resolved, theme: theme, fontFamily: typography.fontFamily, fontSize: typography.codeSize
        )
        let stored = highlighted.copy() as! NSAttributedString
        cache.setObject(stored, forKey: key, cost: code.utf8.count)
        return stored
    }
}

/// Finds the inline links in Markdown source, in order: `[label](destination "title")`,
/// with brackets and parentheses balanced to any depth; `[label][ref]`, `[ref][]`, and `[ref]`
/// for references the source defines; and `<scheme:…>` and email autolinks, whose label is
/// their address. Backslash escapes and code spans are skipped, as the renderer skips them.
private enum MarkdownLinkScanner {
    struct Link {
        let label: String
        let url: String
        let isAutolink: Bool
    }

    static func links(in source: String) -> [Link] {
        let (references, body) = referenceDefinitions(in: source)
        let chars = Array(body)
        var links: [Link] = []
        var index = 0
        while index < chars.count {
            switch chars[index] {
            case "\\":
                index += 2
            case "`":
                index = codeSpanEnd(chars, at: index)
            case "[":
                if let (link, end) = inlineLink(chars, at: index, references: references) {
                    links.append(link)
                    index = end
                } else {
                    index += 1
                }
            case "<":
                if let (link, end) = autolink(chars, at: index) {
                    links.append(link)
                    index = end
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }
        return links
    }

    /// The index after the code span opening at `start`, or after its backtick run if it never closes.
    private static func codeSpanEnd(_ chars: [Character], at start: Int) -> Int {
        var run = 0
        while start + run < chars.count, chars[start + run] == "`" { run += 1 }
        var index = start + run
        while index < chars.count {
            guard chars[index] == "`" else {
                index += 1
                continue
            }
            var closing = 0
            while index + closing < chars.count, chars[index + closing] == "`" { closing += 1 }
            if closing == run { return index + closing }
            index += closing
        }
        return start + run
    }

    /// The `[label]: destination` definitions in `source`, keyed by normalized label, and the
    /// source without them so they aren't read as shortcut references.
    private static func referenceDefinitions(in source: String) -> ([String: String], String) {
        guard source.contains("]:"),
              let regex = try? NSRegularExpression(
                  pattern: #"(?m)^ {0,3}\[((?:[^\[\]\\]|\\.)+)\]:[ \t]*\n?[ \t]*(?:<([^<>\n]*)>|(\S+))(?:[ \t]+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?[ \t]*$"#
              )
        else { return ([:], source) }
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        guard !matches.isEmpty else { return ([:], source) }
        var references: [String: String] = [:]
        for match in matches {
            let destination = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            let key = referenceKey(nsSource.substring(with: match.range(at: 1)))
            if references[key] == nil {
                let unescaped = nsSource.substring(with: destination)
                    .replacingOccurrences(of: #"\\([!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
                references[key] = decodingEntities(unescaped)
            }
        }
        let body = regex.stringByReplacingMatches(in: source, range: NSRange(location: 0, length: nsSource.length), withTemplate: "")
        return (references, body)
    }

    /// The destination with `&amp;` and other character references decoded, as the renderer's URL has them.
    private static func decodingEntities(_ destination: String) -> String {
        guard destination.contains("&") else { return destination }
        return CFXMLCreateStringByUnescapingEntities(nil, destination as CFString, nil) as String? ?? destination
    }

    private static func referenceKey(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `[label][ref]`, `[ref][]`, or `[ref]` whose label closes at `labelEnd`.
    private static func referenceLink(
        _ chars: [Character], label: String, labelEnd: Int, references: [String: String]
    ) -> (Link, Int)? {
        guard !references.isEmpty else { return nil }
        var ref = label
        var end = labelEnd + 1
        if end < chars.count, chars[end] == "[" {
            var index = end + 1
            while index < chars.count, chars[index] != "]" {
                guard chars[index] != "[" else { return nil }
                if chars[index] == "\\" { index += 1 }
                index += 1
            }
            guard index < chars.count else { return nil }
            let inner = String(chars[(end + 1) ..< index])
            if !inner.isEmpty { ref = inner }
            end = index + 1
        }
        guard let url = references[referenceKey(ref)] else { return nil }
        return (Link(label: label, url: url, isAutolink: false), end)
    }

    private static func inlineLink(_ chars: [Character], at start: Int, references: [String: String]) -> (Link, Int)? {
        // Label: balanced brackets.
        var index = start + 1
        var depth = 1
        while index < chars.count {
            switch chars[index] {
            case "\\": index += 1
            case "`": index = codeSpanEnd(chars, at: index) - 1
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
            if depth == 0 { break }
            index += 1
        }
        guard depth == 0 else { return nil }
        let label = String(chars[(start + 1) ..< index])
        guard index + 1 < chars.count, chars[index + 1] == "(" else {
            return referenceLink(chars, label: label, labelEnd: index, references: references)
        }
        index = skipWhitespace(chars, from: index + 2)

        // Destination: `<…>`, or a run without spaces whose parentheses balance.
        var url = ""
        if index < chars.count, chars[index] == "<" {
            index += 1
            while index < chars.count, chars[index] != ">" {
                guard chars[index] != "<", !chars[index].isNewline else { return nil }
                if chars[index] == "\\", index + 1 < chars.count, chars[index + 1].isPunctuationOrSymbol { index += 1 }
                url.append(chars[index])
                index += 1
            }
            guard index < chars.count else { return nil }
            index += 1
        } else {
            var parentheses = 0
            while index < chars.count, !chars[index].isWhitespace {
                let char = chars[index]
                if char == "(" {
                    parentheses += 1
                } else if char == ")" {
                    if parentheses == 0 { break }
                    parentheses -= 1
                } else if char == "\\", index + 1 < chars.count, chars[index + 1].isPunctuationOrSymbol {
                    index += 1
                }
                url.append(chars[index])
                index += 1
            }
            guard parentheses == 0 else { return nil }
        }

        // Optional title after whitespace, then the closing parenthesis.
        let afterDestination = index
        index = skipWhitespace(chars, from: index)
        if index > afterDestination, index < chars.count, let closer = titleCloser(chars[index]) {
            index += 1
            while index < chars.count, chars[index] != closer {
                if chars[index] == "\\" { index += 1 }
                index += 1
            }
            guard index < chars.count else { return nil }
            index = skipWhitespace(chars, from: index + 1)
        }
        guard index < chars.count, chars[index] == ")" else { return nil }
        return (Link(label: label, url: decodingEntities(url), isAutolink: false), index + 1)
    }

    /// `<scheme:…>`, or `<address@domain>`, which renders as a `mailto:` link.
    private static func autolink(_ chars: [Character], at start: Int) -> (Link, Int)? {
        var index = start + 1
        while index < chars.count, chars[index] != ">" {
            guard chars[index] != "<", !chars[index].isWhitespace else { return nil }
            index += 1
        }
        guard index < chars.count else { return nil }
        let content = String(chars[(start + 1) ..< index])
        if content.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:"#, options: .regularExpression) != nil {
            return (Link(label: content, url: content, isAutolink: true), index + 1)
        }
        let email = #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#
        if content.range(of: email, options: .regularExpression) != nil {
            return (Link(label: content, url: "mailto:" + content, isAutolink: true), index + 1)
        }
        return nil
    }

    private static func skipWhitespace(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        return index
    }

    private static func titleCloser(_ char: Character) -> Character? {
        switch char {
        case "\"": "\""
        case "'": "'"
        case "(": ")"
        default: nil
        }
    }
}

private extension Character {
    var isPunctuationOrSymbol: Bool { isASCII && (isPunctuation || isSymbol) }
}
