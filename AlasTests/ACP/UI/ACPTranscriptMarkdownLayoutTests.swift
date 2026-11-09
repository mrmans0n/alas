import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite struct ACPTranscriptMarkdownLayoutTests {
    private var theme: Theme { try! Theme.loadBundled(id: "cool-slate") }

    @Test(arguments: [
        "![alt](https://x/y.png)", "Build: ![badge](https://x/b.png)", "- [ ] task", "```mermaid\ngraph TD\n```",
    ])
    func unsupportedBlocksFallBack(source: String) {
        #expect(ACPTranscriptMarkdownLayout.make(source: source, width: 400, theme: theme, typography: .default) == nil)
    }

    @Test func narrowerWidthIsTallerAndWideGlyphsWrap() throws {
        let source = String(repeating: "漢字 😀 `code` words ", count: 12)
        let wide = try #require(ACPTranscriptMarkdownLayout.make(source: source, width: 600, theme: theme, typography: .default))
        let narrow = try #require(ACPTranscriptMarkdownLayout.make(source: source, width: 200, theme: theme, typography: .default))
        #expect(narrow.height > wide.height)
        #expect(narrow.lines.allSatisfy { CGFloat(CTLineGetTypographicBounds($0.line, nil, nil, nil)) <= 200 + 0.5 })
        #expect(narrow.lines.allSatisfy { line in
            var ascent: CGFloat = 0, descent: CGFloat = 0
            CTLineGetTypographicBounds(line.line, &ascent, &descent, nil)
            return line.height >= ascent + descent
        })
    }

    @Test func blocksAreSpacedAndCodeGetsABackground() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "One.\n\nTwo.\n\n```swift\nlet x = 1\n```", width: 400, theme: theme, typography: .default))
        let tops = layout.lines.map(\.origin.y)
        #expect(tops == tops.sorted())
        #expect(layout.backgrounds.count == 1)
        #expect(layout.backgrounds[0].rect.minY > layout.lines[1].origin.y + layout.lines[1].height + 7.5)
    }

    @Test func codeBlocksAreSyntaxHighlighted() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "```swift\nlet value = 1\n```", width: 400, theme: theme, typography: .default))
        let line = try #require(layout.lines.last)
        let colors = Set((CTLineGetGlyphRuns(line.line) as! [CTRun]).compactMap {
            (CTRunGetAttributes($0) as NSDictionary)[NSAttributedString.Key.foregroundColor] as? NSColor
        })
        #expect(colors.count > 1)
    }

    @Test(arguments: ["let a = 1", "let a = 1\nlet b = 2", "let a = 1\n\nlet b = 2", "let a = 1\n"], [(11, UIDensity.compact), (13, .compact), (13, .comfortable), (16, .compact)])
    func codeBlockHeightMatchesTheSwiftUIBlock(code: String, font: (size: Int, density: UIDensity)) throws {
        let language = "swift"
        let typography = ACPChatTypography(fontFamily: "", fontSize: font.size, density: font.density)
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "```\(language)\n\(code)\n```", width: 500, theme: theme, typography: typography))
        let host = NSHostingView(rootView: CodeBlockView(language: language, code: code, typography: typography)
            .environment(\.theme, theme).frame(width: 500))
        let background = try #require(layout.backgrounds.first)
        #expect(abs(background.rect.height - host.fittingSize.height) < 1)
    }

    @Test(arguments: [
        "| a | b |\n|---|---|\n| 1 | 2 |",
        "| Scenario | p95 | Note |\n|---|---|---|\n| fling | **12 ms** | a longer note that wraps onto a second line in its column |\n| stream | `9 ms` | short |",
        "| | |\n|---|---|\n| a | b |",
        "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOutro.",
    ], [400, 640])
    func tableHeightMatchesTheSwiftUITable(source: String, width: Int) throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: source, width: CGFloat(width), theme: theme, typography: .default
        ))
        let host = NSHostingView(rootView: ACPMarkdownText(raw: source, typography: .default)
            .environment(\.theme, theme).frame(width: CGFloat(width)))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded() // the SwiftUI table reads its viewport width on the next pass
        #expect(abs(layout.height - host.fittingSize.height) < 1)
    }

    /// A native row must be as tall as the SwiftUI row it replaces when a message
    /// finishes, with prose held to the reading column and code and tables past it.
    /// Every width at the default size; 12 and 15pt, where line heights round
    /// differently, at a narrow and a wide one.
    @Test(arguments: [UIDensity.comfortable, .compact], [
        (13, CGFloat(640)), (13, 880), (13, 1_200), (13, 1_600),
        (12, 640), (12, 1_200), (15, 640), (15, 1_200),
    ])
    func rowHeightMatchesTheSwiftUIRow(density: UIDensity, size: (fontSize: Int, rowWidth: CGFloat)) throws {
        let rowWidth = size.rowWidth
        let wideLine = "let row = InvoiceRow(id: invoice.id, title: invoice.title, branch: branch.name, width: width.rounded(), isPinned: false)"
        let source = """
        # A heading

        A paragraph long enough to wrap onto more than one line at every width in this test, \
        which it does by going on for rather longer than any sensible first sentence would, \
        and then carrying on for a while after that so that even the widest column has to wrap.

        ```swift
        \(wideLine)
        return heights[key]
        ```

        | Scenario | Rows | p95 | Worst frame | What changed in this run |
        |---|---|---|---|---|
        | Before the fix | 1,240 | 31.4 ms | 88 ms | Nothing yet, this is the slow path we started from |
        | With identity keys | 14 | 7.1 ms | 12 ms | Keys use identity and a bucketed width |
        """
        let scale = DesignScale.resolved(for: density)
        let typography = ACPChatTypography(fontFamily: "", fontSize: size.fontSize, density: density)
        let columns = ACPChatLayout.transcriptColumns(rowWidth: rowWidth, readingMax: scale.readingColumnMax)

        let row = ACPTranscriptCoreTextRowView(frame: .zero)
        row.configure(
            content: .agent(markdown: source, commentary: false), contentMaxWidth: scale.readingColumnMax,
            inToolCallGroup: false, theme: theme, typography: typography, scale: scale
        )
        let measured = row.measuredHeight(forWidth: rowWidth)
        let drawn = try #require(row.layout(forWidth: rowWidth).items.compactMap { item -> ACPTranscriptMarkdownLayout? in
            if case .markdown(let markdown, _, _) = item { return markdown }
            return nil
        }.first)
        #expect(drawn.width == columns.readingWidth)
        #expect(drawn.backgrounds.first { $0.header != nil }?.rect.width == columns.breakoutWidth)
        #expect(drawn.tables.first?.rect.width == columns.breakoutWidth)

        // A wrapped code line hangs under its first line; the SwiftUI block
        // below breaks at the same narrowed width, or the heights would differ.
        let codeBlock = try #require(drawn.texts.firstIndex { $0.hasPrefix("let row") })
        let codeLines = drawn.lines.filter { $0.block == codeBlock }
        let code = drawn.texts[codeBlock] as NSString
        let lineStartX = try #require(codeLines.first?.origin.x)
        let continues = codeLines.map { $0.range.location > 0 && code.character(at: $0.range.location - 1) != 0x0A }
        for (line, isContinuation) in zip(codeLines, continues) {
            #expect(line.origin.x == lineStartX + (isContinuation ? scale.codeHangingIndent : 0))
        }
        if rowWidth == 640 { #expect(continues.contains(true)) }

        let host = NSHostingView(rootView: ACPTranscriptColumnLayout(readingMax: scale.readingColumnMax, role: .breakout) {
            ACPMarkdownText(raw: source, typography: typography)
                .environment(\.acpMarkdownProseMaxWidth, scale.readingColumnMax)
        }
        .environment(\.theme, theme).environment(\.designScale, scale).frame(width: rowWidth))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded() // the SwiftUI table reads its viewport width on the next pass
        #expect(abs(measured - host.fittingSize.height) <= 1, "native \(measured), SwiftUI \(host.fittingSize.height)")
    }

    @Test(arguments: [
        // A pane that fits everything centers the reading column.
        (CGFloat(1_600), CGFloat(560), CGFloat(520), CGFloat(560), CGFloat(960)),
        // A pane too tight for that moves it left so the breakout width still fits.
        (880, 560, 100, 560, 720),
        // A narrow pane has one column.
        (480, 560, 60, 360, 360),
        // A reading column as wide as the breakout gives one right edge.
        (880, 720, 80, 720, 720),
    ])
    func transcriptColumnsKeepTheBreakoutWidth(
        rowWidth: CGFloat, readingMax: CGFloat, minX: CGFloat, reading: CGFloat, breakout: CGFloat
    ) {
        #expect(ACPChatLayout.transcriptColumns(rowWidth: rowWidth, readingMax: readingMax)
            == .init(minX: minX, readingWidth: reading, breakoutWidth: breakout))
    }

    private func column(_ minWidth: CGFloat, _ idealWidth: CGFloat, numeric: Bool = false) -> ACPTranscriptMarkdownLayout.TableColumn {
        .init(minWidth: minWidth, idealWidth: idealWidth, isNumeric: numeric)
    }

    @Test func spareTableWidthGoesToProseColumns() {
        let widths = ACPTranscriptMarkdownLayout.tableColumnWidths(
            [column(40, 60, numeric: true), column(50, 100)], available: 300.5
        )
        #expect(widths == [60, 240])
    }

    @Test func tightTableShareBeyondLongestWordFollowsWhatColumnsWant() {
        let widths = ACPTranscriptMarkdownLayout.tableColumnWidths(
            [column(50, 50, numeric: true), column(60, 460)], available: 310.5
        )
        #expect(widths == [50, 260])
    }

    @Test func tableThatCannotFitShrinksToTheWidth() {
        let widths = ACPTranscriptMarkdownLayout.tableColumnWidths([column(100, 200), column(200, 400)], available: 150.5)
        #expect(widths == [50, 100])
    }

    @Test(arguments: [
        (["1,240", "96", "14"], true),
        (["2.1 s", "0.4 s"], true),
        (["31 ms", "", "—"], true),
        (["$12", "+5%", "−3", "`42`"], true),
        (["14", "Rebuild the cache"], false),
        (["2026-11-07"], false),
        (["", "-"], false),
    ])
    func numericColumns(cells: [String], expected: Bool) {
        #expect(ACPTranscriptMarkdownLayout.isNumericColumn(cells) == expected)
    }

    @Test func numericColumnsAlignRightAndProseGetsTheWidth() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "| Step | Rows | What it changes |\n|---|---|---|\n| Verify | 1,240 | Checks each invoice total against the source ledger |",
            width: 720, theme: theme, typography: .default
        ))
        let xs = try #require(layout.tables.first?.columnXs)
        #expect(xs.count == 2)
        #expect(xs[1] - xs[0] < 720 - xs[1])
        let number = try #require(layout.lines.first { $0.block.map { layout.texts[$0] } == "1,240" })
        let numberWidth = CGFloat(CTLineGetTypographicBounds(number.line, nil, nil, nil))
        #expect(abs(number.origin.x + numberWidth + ACPTranscriptMarkdownLayout.tableCellHorizontalPadding - xs[1]) <= 1)
    }

    @Test func raggedRowsKeepTheirColumns() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 |", width: 600, theme: theme, typography: .default
        ))
        #expect(layout.texts.count == 9)
        #expect(layout.tables.first?.columnXs.count == 2)
    }

    @Test func aTableNarrowerThanItsColumnsFitsTheWidth() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "| a | b | c | d | e |\n|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 |", width: 300, theme: theme, typography: .default
        ))
        let table = try #require(layout.tables.first)
        #expect(table.rect.maxX <= 300)
        #expect(layout.lines.allSatisfy { $0.maxX <= 300 + 0.5 })
    }

    @Test func everyLineOfAVisibleRowIsFound() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "Intro.\n\n| a | b |\n|---|---|\n| a cell long enough to wrap onto two lines here | 2 |", width: 300, theme: theme, typography: .default
        ))
        let lastRowTop = try #require(layout.tables.first?.rowBottoms.dropLast().last)
        // Past the row's top padding, into its first line of text.
        let found = layout.linesIntersecting(CGRect(
            x: 0, y: lastRowTop + ACPTranscriptMarkdownLayout.tableCellVerticalPadding + 1, width: 300, height: 4
        ))
        #expect(Set(found.compactMap(\.block)).count == 2)
    }

    @Test(arguments: [(5, true), (6, false)])
    func tablesAreSupportedUpToTheColumnCap(columns: Int, expected: Bool) {
        let row = "|" + String(repeating: " x |", count: columns)
        let source = row + "\n|" + String(repeating: "---|", count: columns) + "\n" + row
        #expect(ACPTranscriptMarkdownLayout.supports(ACPMarkdownParser.parse(source)) == expected)
    }

    @Test func aLongCodeLanguageLabelStaysClearOfTheCopyButton() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "```a-very-long-info-string-for-this-code-block\nlet x = 1\n```", width: 200, theme: theme, typography: .default
        ))
        let label = try #require(layout.codeBlocks.first?.label)
        #expect(label.rect.maxX <= layout.copyButtonRect(0, copied: true).minX)
    }

    @Test func aRightToLeftLinkIsOneSpanOverItsGlyphs() throws {
        let label = "שלום עולם"
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "See [\(label)](https://example.com) now.", width: 600, theme: theme, typography: .default
        ))
        let spans = layout.linkSpans()
        #expect(spans.map(\.text) == [label])
        let span = try #require(spans.first)
        let union = span.rects.dropFirst().reduce(span.rects[0]) { $0.union($1) }
        let range = (layout.texts[0] as NSString).range(of: label)
        let labelLine = CTLineCreateWithAttributedString(layout.attributedTexts[0].attributedSubstring(from: range))
        #expect(abs(union.width - CGFloat(CTLineGetTypographicBounds(labelLine, nil, nil, nil))) < 1)
    }

    @Test func separateLinksToOneURLStaySeparate() throws {
        let url = "https://example.com"
        let source = "First [docs](\(url)) here, then plain words in between, and [docs again](\(url)).\n\nNew block [docs](\(url))."
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: source, width: 160, theme: theme, typography: .default))
        #expect(layout.linkSpans().map(\.text) == ["docs", "docs again", "docs"])
    }

    @Test(arguments: [
        "[first](https://example.com) [second](https://example.com)",
        #"[first](https://example.com "one")[second](https://example.com "two")"#,
        "[first](https://example.com 'one')[second](https://example.com 'two')",
        "[first](https://example.com (one))[second](https://example.com (two))",
        "[first](https://example.com/x(y))[second](https://example.com/x(y))",
        "[first](https://example.com/x((y)))[second](https://example.com/x((y)))",
        "[first](<https://example.com>)[second](<https://example.com>)",
        "[first](https://example.com/?x=1&amp;y=2)[second](https://example.com/?x=1&amp;y=2)",
        "[ref]: https://example.com\n[first][ref][second][ref]",
        #"[ref]: https://example.com/a\(b\)"# + "\n[first][ref][second][ref]",
        "[first]: https://example.com\n[second]: https://example.com\n[first][][second][]",
    ])
    func adjacentLinksToOneURLStayDistinct(source: String) throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: source, width: 600, theme: theme, typography: .default))
        #expect(layout.linkSpans().map(\.text) == ["first", "second"])
    }

    @Test func backToBackLinksToOneURLStayDistinct() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "[first](https://example.com)[second](https://example.com) and [a **bold** link](https://example.com)",
            width: 600, theme: theme, typography: .default
        ))
        #expect(layout.linkSpans().map(\.text) == ["first", "second", "a bold link"])
    }

    @Test(arguments: ["<https://example.com><https://example.com>", "<dev@example.com><dev@example.com>"])
    func backToBackAutolinksStayDistinct(source: String) throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: source, width: 800, theme: theme, typography: .default))
        #expect(layout.linkSpans().count == 2)
    }

    @Test(arguments: [
        ("`[decoy](https://example.com)` ", [String]()),
        ("https://example.com ", ["https://example.com"]),
        ("https://example.com [https://example.com](https://example.com)", ["https://example.com", "https://example.com"]),
        (#"\[decoy](https://other.example) "#, ["https://other.example"]),
        (#"\[decoy](https://example.com) "#, ["https://example.com"]),
    ])
    func linkLikeTextBeforeLinksDoesNotShiftTheirBoundaries(prefix: String, leadingSpans: [String]) throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: prefix + "[first](https://example.com)[second](https://example.com)",
            width: 800, theme: theme, typography: .default
        ))
        #expect(layout.linkSpans().map(\.text) == leadingSpans + ["first", "second"])
    }

    @Test func aWrappedLinkIsOneSpan() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "Read [the full migration guide for this release](https://example.com) first.", width: 120,
            theme: theme, typography: .default
        ))
        let spans = layout.linkSpans()
        #expect(spans.count == 1)
        #expect(spans.first?.text == "the full migration guide for this release")
        #expect((spans.first?.rects.count ?? 0) > 1)
    }

    @Test func aLinkWrappedInACellIsOneSpanBesideALinkInTheNextCell() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "| a | b |\n|---|---|\n| [the full migration guide for this release](https://example.com/guide) | [docs](https://example.com/docs) |",
            width: 240, theme: theme, typography: .default
        ))
        let spans = layout.linkSpans()
        #expect(spans.map(\.text) == ["the full migration guide for this release", "docs"])
        #expect((spans.first?.rects.count ?? 0) > 1)
    }

    @Test func linksAreStyledAndHitTestable() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "See [docs](https://example.com) now.", width: 400, theme: theme, typography: .default))
        let line = try #require(layout.lines.first)
        let runs = CTLineGetGlyphRuns(line.line) as! [CTRun]
        let linkRun = try #require(runs.first { (CTRunGetAttributes($0) as NSDictionary)[NSAttributedString.Key.link] != nil })
        let attributes = CTRunGetAttributes(linkRun) as NSDictionary
        #expect((attributes[NSAttributedString.Key.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
        #expect(layout.lines[0].underlines.count == 1)
        let x = CTLineGetOffsetForStringIndex(line.line, CTRunGetStringRange(linkRun).location + 1, nil)
        #expect(layout.link(at: CGPoint(x: x, y: line.origin.y + line.height / 2)) == URL(string: "https://example.com"))
        #expect(layout.link(at: CGPoint(x: 1, y: line.origin.y + line.height / 2)) == nil)
        #expect(layout.link(at: CGPoint(x: 399, y: line.origin.y + line.height / 2)) == nil)
        #expect(layout.link(at: CGPoint(x: x, y: line.origin.y + line.height + 50)) == nil)
    }

    @Test func linksInLaterColumnsAreHitTested() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "| a | b |\n|---|---|\n| plain | [docs](https://example.com) |", width: 400, theme: theme, typography: .default
        ))
        let span = try #require(layout.linkSpans().first)
        #expect(layout.link(at: CGPoint(x: span.rects[0].midX, y: span.rects[0].midY))?.absoluteString == "https://example.com")
    }

    /// A caret index past the glyph's midpoint is the run's end, so hit
    /// testing has to use the run's drawn bounds instead.
    @Test func theTrailingHalfOfALinkGlyphStillHitsTheLink() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "See [x](https://example.com) now.", width: 400, theme: theme, typography: .default))
        let line = try #require(layout.lines.first)
        let runs = CTLineGetGlyphRuns(line.line) as! [CTRun]
        let linkRun = try #require(runs.first { (CTRunGetAttributes($0) as NSDictionary)[NSAttributedString.Key.link] != nil })
        var position = CGPoint.zero
        CTRunGetPositions(linkRun, CFRange(location: 0, length: 1), &position)
        let width = CGFloat(CTRunGetTypographicBounds(linkRun, CFRange(location: 0, length: 0), nil, nil, nil))
        let y = line.origin.y + line.height / 2
        #expect(layout.link(at: CGPoint(x: line.origin.x + position.x + width * 0.9, y: y)) == URL(string: "https://example.com"))
        #expect(layout.link(at: CGPoint(x: line.origin.x + position.x + width + 0.5, y: y)) == nil)
    }

    @Test func linesIntersectingIncludesLinesCutByTheRect() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: String(repeating: "word ", count: 400), width: 300, theme: theme, typography: .default))
        let second = layout.lines[1]
        let cut = CGRect(x: 0, y: second.origin.y + second.height / 2, width: 300, height: 1)
        #expect(layout.linesIntersecting(cut).map(\.origin.y) == [second.origin.y])
    }

    @Test func blankCodeLinesDrawNothingOfTheirNeighbours() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "```\na\n\nb\n```", width: 400, theme: theme, typography: .default))
        #expect(layout.lines.count == 3)
        // "a", the blank line, and "b": only the two letters are drawn, each once.
        #expect(layout.lines.map { CTLineGetStringRange($0.line).length } == [1, 0, 1])
        #expect(layout.lines.map(\.origin.y) == layout.lines.map(\.origin.y).sorted())
    }
}
