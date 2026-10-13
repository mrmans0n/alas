import AppKit
import CoreText
import Testing
@testable import Alas

@MainActor
@Suite struct ACPTranscriptMarkdownLayoutTests {
    private var theme: Theme { try! Theme.loadBundled(id: "cool-slate") }

    @Test(arguments: ["| a | b |\n|---|---|\n| 1 | 2 |", "![alt](https://x/y.png)", "- [ ] task", "```mermaid\ngraph TD\n```"])
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
