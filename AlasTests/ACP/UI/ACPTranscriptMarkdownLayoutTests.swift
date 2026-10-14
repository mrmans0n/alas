import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite struct ACPTranscriptMarkdownLayoutTests {
    private var theme: Theme { try! Theme.loadBundled(id: "cool-slate") }

    @Test(arguments: ["| a | b |\n|---|---|\n| 1 | 2 |", "![alt](https://x/y.png)", "Build: ![badge](https://x/b.png)", "- [ ] task", "```mermaid\ngraph TD\n```"])
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

    @Test(arguments: ["let a = 1", "let a = 1\nlet b = 2", "let a = 1\n\nlet b = 2"], [11, 13, 16])
    func codeBlockHeightMatchesTheSwiftUIBlock(code: String, fontSize: Int) throws {
        let language = "swift"
        let typography = ACPChatTypography(fontFamily: "", fontSize: fontSize)
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: "```\(language)\n\(code)\n```", width: 500, theme: theme, typography: typography))
        let host = NSHostingView(rootView: CodeBlockView(language: language, code: code, typography: typography)
            .environment(\.theme, theme).frame(width: 500))
        let background = try #require(layout.backgrounds.first)
        #expect(abs(background.rect.height - host.fittingSize.height) < 1)
    }

    @Test func separateLinksToOneURLStaySeparate() throws {
        let url = "https://example.com"
        let source = "First [docs](\(url)) here, then plain words in between, and [docs again](\(url)).\n\nNew block [docs](\(url))."
        let layout = try #require(ACPTranscriptMarkdownLayout.make(source: source, width: 160, theme: theme, typography: .default))
        #expect(layout.linkSpans().map(\.text) == ["docs", "docs again", "docs"])
    }

    @Test func adjacentLinksToOneURLStayDistinct() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "[first](https://example.com) [second](https://example.com)", width: 600, theme: theme, typography: .default
        ))
        #expect(layout.linkSpans().map(\.text) == ["first", "second"])
    }

    @Test func backToBackLinksToOneURLStayDistinct() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "[first](https://example.com)[second](https://example.com) and [a **bold** link](https://example.com)",
            width: 600, theme: theme, typography: .default
        ))
        #expect(layout.linkSpans().map(\.text) == ["first", "second", "a bold link"])
    }

    @Test func backToBackAutolinksStayDistinct() throws {
        let layout = try #require(ACPTranscriptMarkdownLayout.make(
            source: "<https://example.com><https://example.com>", width: 800, theme: theme, typography: .default
        ))
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
