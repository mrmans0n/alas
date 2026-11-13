import Foundation
import Markdown

enum MarkdownBlock: Equatable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case code(language: String?, text: String)
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
        case let c as CodeBlock: .code(language: c.language, text: c.code.trimmingCharacters(in: .newlines))
        case let l as UnorderedList: .list(l.listItems.map { inline($0) })
        case let l as OrderedList: .list(l.listItems.map { inline($0) })
        case let q as BlockQuote: .quote(inline(q))
        case let t as Markdown.Table:
            .table(([Array(t.head.cells)] + t.body.rows.map { Array($0.cells) }).map { $0.map(\.plainText) })
        default: nil
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

    private var entries: [String: (revision: Int, blocks: [MarkdownBlock])] = [:]

    /// Keeps only the newest revision per id, so a streaming row re-parses only itself.
    func blocks(id: String, revision: Int, text: String) -> [MarkdownBlock] {
        if let hit = entries[id], hit.revision == revision { return hit.blocks }
        let blocks = MarkdownBlock.parse(text)
        entries[id] = (revision, blocks)
        return blocks
    }
}
