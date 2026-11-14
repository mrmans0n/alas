import Foundation
import Markdown

enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    /// Split into runs of `codeChunkLines` lines so a long listing lays out and draws as many
    /// small texts instead of one view thousands of points tall.
    case code(language: String?, chunks: [String])
    case list([AttributedString])
    case quote(AttributedString)
    case table([[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        Document(parsing: text).children.compactMap(block)
    }

    private static func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let p as Paragraph: .paragraph(inline(p))
        case let h as Heading: .heading(h.level, inline(h))
        case let c as CodeBlock: .code(language: c.language, chunks: chunked(c.code.trimmingCharacters(in: .newlines)))
        case let l as UnorderedList: .list(l.listItems.map { inline($0) })
        case let l as OrderedList: .list(l.listItems.map { inline($0) })
        case let q as BlockQuote: .quote(inline(q))
        case let t as Markdown.Table:
            .table(([Array(t.head.cells)] + t.body.rows.map { Array($0.cells) }).map { $0.map(\.plainText) })
        default: nil
        }
    }

    static let codeChunkLines = 100

    private static func chunked(_ code: String) -> [String] {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        return stride(from: 0, to: lines.count, by: codeChunkLines).map {
            lines[$0 ..< min($0 + codeChunkLines, lines.count)].joined(separator: "\n")
        }
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
