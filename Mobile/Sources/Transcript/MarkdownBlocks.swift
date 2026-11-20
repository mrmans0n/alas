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
    case table(header: [AttributedString], rows: [[AttributedString]])
    /// `![alt](source)` on its own line; inside other text an image reads as its alt text.
    case image(source: String, alt: String)
    /// A closed ```` ```mermaid ```` fence, drawn as a diagram.
    case mermaid(source: String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })  // cmark's line endings only, so line numbers match
        return Document(parsing: text).children.compactMap { block($0, lines: lines) }
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
                .code(language: c.language, chunks: highlighted(c.code, language: nil))
            } else if MermaidFence.isMermaid(language: c.language) {
                .mermaid(source: c.code)
            } else {
                .code(language: c.language, chunks: highlighted(c.code, language: c.language))
            }
        case let l as ListItemContainer: .list(entries(l, depth: 0, lines: lines))
        case let q as BlockQuote: .quote(inline(q))
        case let t as Markdown.Table:
            .table(header: t.head.cells.map { inline($0) }, rows: t.body.rows.map { $0.cells.map { inline($0) } })
        default: nil
        }
    }

    static let codeChunkLines = 100

    private static func isClosed(_ block: CodeBlock, lines: [Substring]) -> Bool {
        guard let range = block.range, !lines.isEmpty else { return true }
        let first = min(max(range.lowerBound.line - 1, 0), lines.count - 1)
        let last = min(max(range.upperBound.line - 1, first), lines.count - 1)
        return CodeFence.isClosed(Array(lines[first ... last]))
    }

    /// Highlights the whole block once, then splits it, so a construct spanning a chunk
    /// boundary (a block comment, a multi-line string) still colours on both sides.
    private static func highlighted(_ code: String, language: String?) -> [CodeChunk] {
        let source = code.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        let spans = ACPCodeLanguage.highlighterExtension(for: language)
            .map { TreeSitterHighlighter.highlight(source: source, fileExtension: $0) } ?? []
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
    }

    /// The benchmark clears it per run: a warm cache would make every open after the first look
    /// cheaper than a real cold open.
    func removeAll() {
        entries.removeAll()
    }
}
