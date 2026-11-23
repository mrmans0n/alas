import AlasHighlight
import AlasRemoteKit
import Foundation
import Markdown
import SwiftUI

struct CodeChunk: Equatable {
    let text: String
    /// Rebased to `text`; coloured at draw time so a light/dark switch never re-highlights.
    let spans: [HighlightSpan]
}

enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    /// Split into runs of `codeChunkLines` lines so a long listing lays out and draws as many
    /// small texts instead of one view thousands of points tall.
    case code(language: String?, chunks: [CodeChunk])
    case list([ListEntry])
    case quote(AttributedString)
    /// A GitHub `> [!NOTE]`-style alert, as on the Mac.
    case alert(MarkdownAlert.Kind, AttributedString)
    case table(header: [AttributedString], rows: [[AttributedString]])
    /// `![alt](source)` on its own line; inside other text an image reads as its alt text.
    case image(source: String, alt: String)
    /// A closed ```` ```mermaid ```` fence, drawn as a diagram.
    case mermaid(source: String)
    /// A closed ```` ```visual ```` fence: HTML drawn inline as an embedded visual aid, as on the Mac.
    case visual(ACPVisualAid)
    /// A ```` ```visual ```` fence still streaming: a label stands in, so raw HTML never shows as code.
    case drawingVisual(title: String?)
    /// A closed ```` ```chart ```` fence, drawn natively as on the Mac.
    case chart(ChartSpec)
    /// A GitHub `<details>` section, folded under its summary as on the Mac. See `MarkdownDetails`.
    case details(summary: AttributedString, isOpen: Bool, blocks: [MarkdownBlock])

    /// The text's blocks. `<details>` sections are cut out first, since cmark reads their tags as HTML
    /// that ends at a blank line, and each part is parsed on its own.
    static func parse(_ text: String) -> [MarkdownBlock] {
        MarkdownDetails.split(text).flatMap { segment -> [MarkdownBlock] in
            switch segment {
            case .markdown(let markdown): parseMarkdown(markdown)
            case .details(let section):
                [.details(summary: summaryText(section.summary), isOpen: section.isOpen, blocks: parse(section.body))]
            }
        }
    }

    private static func summaryText(_ summary: String) -> AttributedString {
        guard let paragraph = Document(parsing: summary).child(at: 0) as? Paragraph else { return AttributedString(summary) }
        return inline(paragraph)
    }

    private static func parseMarkdown(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })  // cmark's line endings only, so line numbers match
        return Document(parsing: text).children.compactMap { block($0, lines: lines) }
    }

    /// The 1-based lines (as cmark counts them) of top-level code blocks and
    /// tables: blocks drawn from their text alone, without inline chips.
    static func verbatimLines(in text: String) -> [ClosedRange<Int>] {
        Document(parsing: text).children.compactMap { child in
            guard child is CodeBlock || child is Markdown.Table, let range = child.range else { return nil }
            return range.lowerBound.line ... max(range.lowerBound.line, range.upperBound.line)
        }
    }

    private static func block(_ markup: Markup, lines: [Substring]) -> MarkdownBlock? {
        switch markup {
        case let p as Paragraph:
            if p.childCount == 1, let image = p.child(at: 0) as? Markdown.Image {
                .image(source: image.source ?? "", alt: image.plainText)
            } else {
                .paragraph(inline(p))
            }
        case let h as Heading: .heading(h.level, inline(h))
        case let c as CodeBlock:
            // As on the Mac, a fence still streaming stays plain: re-highlighting or drawing it per delta is too slow.
            if !isClosed(c, lines: lines) {
                VisualFence.isVisual(language: c.language)
                    ? .drawingVisual(title: VisualFence.title(language: c.language))
                    : .code(language: c.language, chunks: highlighted(c.code, language: nil))
            } else if MermaidFence.isMermaid(language: c.language) {
                .mermaid(source: c.code)
            } else if let chart = ChartSpec(language: c.language, code: c.code) {
                .chart(chart)
            } else if let html = VisualFence.html(language: c.language, code: c.code) {
                // Same id as the Mac derives from the HTML, so a re-parse keeps the page and its height.
                .visual(.fenced(title: VisualFence.title(language: c.language), html: html))
            } else {
                .code(language: c.language, chunks: highlighted(c.code, language: c.language))
            }
        case let l as ListItemContainer: .list(entries(l, depth: 0, lines: lines))
        case let q as BlockQuote:
            if let (kind, _) = MarkdownAlert.match(quotedLines(q, lines: lines)) {
                .alert(kind, droppingAlertMarker(inline(q)))
            } else {
                .quote(inline(q))
            }
        case let t as Markdown.Table:
            .table(header: t.head.cells.map { inline($0) }, rows: t.body.rows.map { $0.cells.map { inline($0) } })
        default: nil
        }
    }

    static let codeChunkLines = 100

    /// The quote's source lines without their `>` prefix, which the marker check reads.
    private static func quotedLines(_ quote: BlockQuote, lines: [Substring]) -> [String] {
        guard let range = quote.range, !lines.isEmpty else { return [] }
        let first = min(max(range.lowerBound.line - 1, 0), lines.count - 1)
        let last = min(max(range.upperBound.line - 1, first), lines.count - 1)
        return lines[first ... last].map { line in
            var s = Substring(line.drop { $0 == " " })
            if s.first == ">" { s = s.dropFirst() }
            if s.first == " " { s = s.dropFirst() }
            return String(s)
        }
    }

    /// The quote's text after its `[!KIND]` marker. Rendered from the quote as parsed, not re-parsed,
    /// so reference links whose definitions sit elsewhere in the message still resolve.
    private static func droppingAlertMarker(_ text: AttributedString) -> AttributedString {
        let chars = text.characters
        guard let close = chars.firstIndex(of: "]") else { return text }
        var start = chars.index(after: close)
        while start < chars.endIndex, chars[start].isWhitespace { start = chars.index(after: start) }
        return AttributedString(text[start...])
    }

    private static func isClosed(_ block: CodeBlock, lines: [Substring]) -> Bool {
        guard let range = block.range, !lines.isEmpty else { return true }
        let first = min(max(range.lowerBound.line - 1, 0), lines.count - 1)
        let last = min(max(range.upperBound.line - 1, first), lines.count - 1)
        return CodeFence.isClosed(Array(lines[first ... last]))
    }

    /// Highlights the whole block once, then splits it, so a construct spanning a chunk
    /// boundary (a block comment, a multi-line string) still colours on both sides.
    private static func highlighted(_ code: String, language: String?) -> [CodeChunk] {
        highlighted(code, fileExtension: ACPCodeLanguage.highlighterExtension(for: language))
    }

    /// A file's code, coloured by its path's language, in drawable chunks.
    static func codeChunks(_ code: String, path: String) -> [CodeChunk] {
        highlighted(code, fileExtension: ACPCodeLanguage.highlighterExtension(forPath: path))
    }

    private static func highlighted(_ code: String, fileExtension: String?) -> [CodeChunk] {
        let source = code.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        let spans = fileExtension.map { TreeSitterHighlighter.highlight(source: source, fileExtension: $0) } ?? []
        return HighlightChunks.split(source: source, spans: spans, linesPerChunk: codeChunkLines)
            .map { CodeChunk(text: $0.text, spans: $0.spans) }
    }

    /// One entry per item, each nested list's items following their parent one level deeper.
    private static func entries(_ list: ListItemContainer, depth: Int, lines: [Substring]) -> [ListEntry] {
        var out: [ListEntry] = []
        for (offset, item) in list.listItems.enumerated() {
            let marker: ListEntry.Marker = if let box = item.checkbox {
                .task(checked: box == .checked)
            } else if let ordered = list as? OrderedList {
                .number(writtenNumber(item, lines: lines) ?? "\(Int(ordered.startIndex) + offset).")
            } else {
                .bullet
            }
            // Children keep source order: text so far becomes the item's entry when a nested list
            // starts, and text after it continues at this depth under a blank marker.
            var text = AttributedString()
            var emitted = false
            func flush() {
                out.append(ListEntry(depth: depth, marker: emitted ? .continuation(marker) : marker, text: text))
                emitted = true
                text = AttributedString()
            }
            for child in item.children {
                if let sublist = child as? ListItemContainer {
                    if !emitted || !text.characters.isEmpty { flush() }
                    out += entries(sublist, depth: depth + 1, lines: lines)
                } else {
                    let piece = part(child)
                    if !piece.characters.isEmpty, !text.characters.isEmpty { text += AttributedString("\n") }
                    text += piece
                }
            }
            if !emitted || !text.characters.isEmpty { flush() }
        }
        return out
    }

    /// The marker as the source wrote it (`1. 1. 1.` stays 1, 1, 1), delimiter included, as on the Mac.
    /// swift-markdown's columns are 1-based UTF-8 byte offsets into the line.
    private static func writtenNumber(_ item: ListItem, lines: [Substring]) -> String? {
        guard let start = item.range?.lowerBound, lines.indices.contains(start.line - 1) else { return nil }
        let rest = lines[start.line - 1].utf8.dropFirst(start.column - 1)
        let digits = rest.prefix { (48 ... 57).contains($0) }
        guard !digits.isEmpty, let delimiter = rest.dropFirst(digits.count).first,
              delimiter == UInt8(ascii: ".") || delimiter == UInt8(ascii: ")") else { return nil }
        return String(decoding: digits, as: UTF8.self) + String(UnicodeScalar(delimiter))
    }

    /// Flattens a block's inline descendants (paragraphs inside list items and quotes join with a newline).
    private static func inline(_ markup: Markup) -> AttributedString {
        var out = AttributedString()
        for child in markup.children {
            let piece = part(child)
            if child is BlockMarkup, !piece.characters.isEmpty, !out.characters.isEmpty { out += AttributedString("\n") }
            out += piece
        }
        return out
    }

    /// One child of a flattened block: a fence inside a list item or quote reads as inline code
    /// rather than vanishing, another block flattens in turn, inline markup keeps its styling.
    private static func part(_ child: Markup) -> AttributedString {
        if let code = child as? CodeBlock { return styled(code.code.trimmingCharacters(in: .newlines), .code) }
        return child is BlockMarkup ? inline(child) : run(child, [])
    }

    private static func run(_ markup: Markup, _ intent: InlinePresentationIntent) -> AttributedString {
        switch markup {
        case let t as Markdown.Text: return styled(t.string, intent)
        case is SoftBreak: return AttributedString(" ")
        case is LineBreak: return AttributedString("\n")
        case let c as InlineCode:
            var text = styled(c.code, intent.union(.code))
            text.link = RemoteRunPreview.inlineURL(c.code)
            return text
        case let l as Markdown.Link:
            var s = markup.children.reduce(into: AttributedString()) { $0 += run($1, intent) }
            if let d = l.destination, let url = URL(string: d) { s.link = url }
            return s
        default:
            var next = intent
            if markup is Strong { next.insert(.stronglyEmphasized) }
            if markup is Emphasis { next.insert(.emphasized) }
            if markup is Strikethrough { next.insert(.strikethrough) }
            return markup.children.reduce(into: AttributedString()) { $0 += run($1, next) }
        }
    }

    private static func styled(_ s: String, _ intent: InlinePresentationIntent) -> AttributedString {
        var a = AttributedString(s)
        var intent = intent
        if intent.contains(.code) {
            // Monospaced glyphs read larger than body text at the same size: a step down, on a tint, as on the Mac.
            intent.remove(.code)
            a.font = .system(.callout, design: .monospaced)
            a.backgroundColor = Color.secondary.opacity(0.12)
        }
        if !intent.isEmpty { a.inlinePresentationIntent = intent }
        return a
    }
}

struct ListEntry: Equatable {
    indirect enum Marker: Equatable {
        case bullet
        /// As written, delimiter included: "3." or "1)".
        case number(String)
        case task(checked: Bool)
        /// Text after a nested list: no marker of its own, but the width of the item's `marker`.
        case continuation(Marker)
    }

    let depth: Int
    let marker: Marker
    let text: AttributedString
}

@MainActor
final class MarkdownBlockCache {
    static let shared = MarkdownBlockCache()

    private var entries: [String: (text: String, blocks: [MarkdownBlock])] = [:]
    /// The `<details>` sections the reader opened or closed against their tag, by key, so a reused
    /// cell keeps them as they were.
    var toggledDetails: Set<String> = []

    /// Keeps only the newest text per id, so a streaming row re-parses only itself. Keyed on the
    /// text itself, so a changed message can never be served stale blocks; an unchanged row's
    /// text usually shares storage with the cached copy, which makes the comparison cheap.
    func blocks(id: String, text: String) -> [MarkdownBlock] {
        if let hit = entries[id], hit.text == text { return hit.blocks }
        let blocks = MarkdownBlock.parse(text)
        entries[id] = (text, blocks)
        return blocks
    }

    /// A closing transcript drops its rows, so the cache never outlives what is on screen.
    func remove(ids: [String]) {
        for id in ids {
            entries[id] = nil
        }
        if !toggledDetails.isEmpty {
            toggledDetails = toggledDetails.filter { key in !ids.contains { key.hasPrefix($0 + ":") } }
        }
    }

    /// The benchmark clears it per run: a warm cache would make every open after the first look
    /// cheaper than a real cold open.
    func removeAll() {
        entries.removeAll()
        toggledDetails.removeAll()
    }
}
