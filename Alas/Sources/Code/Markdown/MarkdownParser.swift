import Foundation
import Markdown

struct MarkdownParseResult {
    let document: Document
    let frontmatter: MarkdownFrontmatter?
}

struct MarkdownFrontmatter: Equatable {
    let entries: [MarkdownFrontmatterEntry]

    var isEmpty: Bool {
        entries.isEmpty
    }
}

struct MarkdownFrontmatterEntry: Equatable {
    let key: String
    let value: String
}

/// Thin wrapper over `swift-markdown`'s `Document.init(parsing:options:)`.
/// Provides a single, tested entry point so the renderer never has to
/// remember the option set. GFM tables, task lists, strikethrough, and
/// autolinks are enabled by default in current `swift-markdown` releases.
enum MarkdownParser {
    static func parse(_ source: String) -> MarkdownParseResult {
        let extracted = extractFrontmatter(from: source)
        return MarkdownParseResult(
            document: Document(parsing: extracted.body),
            frontmatter: extracted.frontmatter
        )
    }

    static func parseDocument(_ source: String) -> Document {
        parse(source).document
    }

    private static func extractFrontmatter(from source: String) -> (frontmatter: MarkdownFrontmatter?, body: String) {
        guard let opening = firstLine(in: source),
              trimmedDelimiter(opening.text) == "---" else {
            return (nil, source)
        }

        var searchIndex = opening.fullRange.upperBound
        while searchIndex < source.endIndex {
            guard let line = line(in: source, startingAt: searchIndex) else {
                break
            }
            if trimmedDelimiter(line.text) == "---" {
                let frontmatterText = String(source[opening.fullRange.upperBound..<line.fullRange.lowerBound])
                guard let entries = parseFrontmatterEntries(frontmatterText),
                      !entries.isEmpty else {
                    return (nil, source)
                }
                let frontmatter = MarkdownFrontmatter(entries: entries)
                let body = String(source[line.fullRange.upperBound...])
                return (frontmatter, body)
            }
            searchIndex = line.fullRange.upperBound
        }

        return (nil, source)
    }

    private static func parseFrontmatterEntries(_ source: String) -> [MarkdownFrontmatterEntry]? {
        var entries: [MarkdownFrontmatterEntry] = []
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            guard rawLine.first?.isWhitespace != true else { return nil }
            guard let separator = line.firstIndex(of: ":") else { return nil }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }

            let valueStart = line.index(after: separator)
            let rawValue = line[valueStart...].trimmingCharacters(in: .whitespaces)
            entries.append(MarkdownFrontmatterEntry(
                key: String(key),
                value: stripMatchingQuotes(from: String(rawValue))
            ))
        }
        return entries
    }

    private static func stripMatchingQuotes(from value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func firstLine(in source: String) -> (text: Substring, fullRange: Range<String.Index>)? {
        guard !source.isEmpty else { return nil }
        return line(in: source, startingAt: source.startIndex)
    }

    private static func line(
        in source: String,
        startingAt start: String.Index
    ) -> (text: Substring, fullRange: Range<String.Index>)? {
        guard start < source.endIndex else { return nil }

        let lineEnd = source[start...].firstIndex(of: "\n") ?? source.endIndex
        var textEnd = lineEnd
        if textEnd > start {
            let beforeEnd = source.index(before: textEnd)
            if source[beforeEnd] == "\r" {
                textEnd = beforeEnd
            }
        }

        let fullEnd = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex
        return (source[start..<textEnd], start..<fullEnd)
    }

    private static func trimmedDelimiter(_ text: Substring) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }
}
