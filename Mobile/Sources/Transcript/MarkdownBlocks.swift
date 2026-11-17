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
    case list([AttributedString])
    case quote(AttributedString)
    case table([[String]])
    /// `![alt](source)` on its own line; inside other text an image reads as its alt text.
    case image(source: String, alt: String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        Document(parsing: text).children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let p as Paragraph:
            if p.childCount == 1, let image = p.child(at: 0) as? Markdown.Image {
                .image(source: image.source ?? "", alt: image.plainText)
            } else {
                .paragraph(inline(p))
            }
        case let h as Heading: .heading(h.level, inline(h))
        case let c as CodeBlock: .code(language: c.language, chunks: highlighted(c.code, language: c.language))
        case let l as UnorderedList: .list(l.listItems.map { inline($0) })
        case let l as OrderedList: .list(l.listItems.map { inline($0) })
        case let q as BlockQuote: .quote(inline(q))
        case let t as Markdown.Table:
            .table(([Array(t.head.cells)] + t.body.rows.map { Array($0.cells) }).map { $0.map(\.plainText) })
        default: nil
        }
    }

    static let codeChunkLines = 100

    /// Highlights the whole block once, then splits it, so a construct spanning a chunk
    /// boundary (a block comment, a multi-line string) still colours on both sides.
    private static func highlighted(_ code: String, language: String?) -> [CodeChunk] {
        let source = code.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
        let spans = ACPCodeLanguage.highlighterExtension(for: language)
            .map { TreeSitterHighlighter.highlight(source: source, fileExtension: $0) } ?? []
        return HighlightChunks.split(source: source, spans: spans, linesPerChunk: codeChunkLines)
            .map { CodeChunk(text: $0.text, spans: $0.spans) }
    }

    /// Flattens a block's inline descendants (paragraphs inside list items and quotes join with a newline).
    private static func inline(_ markup: Markup) -> AttributedString {
        var out = AttributedString()
        for child in markup.children {
            if child is BlockMarkup {
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
