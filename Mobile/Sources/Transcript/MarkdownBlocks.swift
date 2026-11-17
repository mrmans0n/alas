import AlasHighlight
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

    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
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
            // As on the Mac, a fence still streaming stays plain: re-highlighting it per delta is too slow.
            .code(language: c.language, chunks: highlighted(c.code, language: isClosed(c, lines: lines) ? c.language : nil))
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
            var text = AttributedString()
            var nested: [ListEntry] = []
            for child in item.children {
                if let sublist = child as? ListItemContainer {
                    nested += entries(sublist, depth: depth + 1, lines: lines)
                } else {
                    if !text.characters.isEmpty { text += AttributedString("\n") }
                    text += inline(child)
                }
            }
            out.append(ListEntry(depth: depth, marker: marker, text: text))
            out += nested
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
            if let code = child as? CodeBlock {
                // A fence inside a list item or quote reads as inline code rather than vanishing.
                if !out.characters.isEmpty { out += AttributedString("\n") }
                out += styled(code.code.trimmingCharacters(in: .newlines), .code)
            } else if child is BlockMarkup {
                if !out.characters.isEmpty { out += AttributedString("\n") }
                out += inline(child)
            } else {
                out += run(child, [])
            }
        }
        return out
    }

    private static func run(_ markup: Markup, _ intent: InlinePresentationIntent) -> AttributedString {
        switch markup {
        case let t as Markdown.Text: return styled(t.string, intent)
        case is SoftBreak: return AttributedString(" ")
        case is LineBreak: return AttributedString("\n")
        case let c as InlineCode: return styled(c.code, intent.union(.code))
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
    enum Marker: Equatable {
        case bullet
        /// As written, delimiter included: "3." or "1)".
        case number(String)
        case task(checked: Bool)
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
