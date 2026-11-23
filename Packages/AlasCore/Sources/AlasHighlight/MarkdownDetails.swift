import Foundation

/// GitHub's collapsible sections:
///
///     <details>
///     <summary>Full test output</summary>
///
///     …any markdown…
///
///     </details>
///
/// Only `<details>` and `<summary>` are read, each tag starting its line; `<details open>` starts
/// expanded. A section without a summary is titled "Details", as on GitHub, and one whose closing tag
/// has not arrived yet runs to the end of the text. Shared by the Mac's markdown parser and the
/// phone's, like `MarkdownAlert`.
public enum MarkdownDetails: Sendable {
    public struct Section: Equatable, Sendable {
        public let summary: String
        public let isOpen: Bool
        /// The markdown inside, without the summary.
        public let body: String

        public init(summary: String, isOpen: Bool, body: String) {
            self.summary = summary
            self.isOpen = isOpen
            self.body = body
        }
    }

    public enum Segment: Equatable, Sendable {
        case markdown(String)
        case details(Section)
    }

    public static let defaultSummary = "Details"
    private static let closeTag = "</details>"

    /// How a line outside code fences moves the nesting depth: 1 when it opens a section, -1 when it
    /// closes one, 0 otherwise, as `section(in:at:)` counts them. A tag indented four spaces or more
    /// is an indented code block's text, as in CommonMark, so it counts for nothing.
    public static func depthChange(_ line: some StringProtocol) -> Int {
        guard !isIndentedCode(line) else { return 0 }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let open = opening(trimmed) { return open.rest.range(of: closeTag, options: .caseInsensitive) == nil ? 1 : 0 }
        return trimmed.lowercased().hasPrefix(closeTag) ? -1 : 0
    }

    /// The section `lines[start]` opens, how many lines it spans, and any text after its closing tag on
    /// the last of them; nil when the line opens none.
    public static func section(
        in lines: [String], at start: Int
    ) -> (section: Section, lineCount: Int, trailing: String?)? {
        guard lines.indices.contains(start), !isIndentedCode(lines[start]),
              let open = opening(lines[start].trimmingCharacters(in: .whitespaces))
        else { return nil }
        var inner: [String] = []
        var trailing: String?
        var end = start + 1
        var closed = false
        if let close = open.rest.range(of: closeTag, options: .caseInsensitive) {
            inner.append(String(open.rest[..<close.lowerBound]))
            let after = open.rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
            trailing = after.isEmpty ? nil : after
            closed = true
        } else if !open.rest.isEmpty {
            inner.append(String(open.rest))
        }
        var depth = 1
        var fence: Fence?
        while !closed, end < lines.count {
            let line = lines[end]
            end += 1
            if let current = fence {
                if current.isClosed(by: line) { fence = nil }
            } else if let opened = Fence(opening: line) {
                fence = opened
            } else {
                depth += depthChange(line)
                if depth == 0 {
                    let after = line.trimmingCharacters(in: .whitespaces).dropFirst(closeTag.count)
                        .trimmingCharacters(in: .whitespaces)
                    trailing = after.isEmpty ? nil : after
                    closed = true
                    break
                }
            }
            inner.append(line)
        }
        let (summary, body) = summaryAndBody(inner)
        return (Section(summary: summary, isOpen: open.isOpen, body: body), end - start, trailing)
    }

    /// `text` cut at its top-level sections, in order. When it has a section, every segment and section
    /// body also gets the text's link reference definitions, since each is rendered on its own.
    public static func split(_ text: String) -> [Segment] {
        var lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var prose: [String] = []
        var definitions: [String] = []
        var fence: Fence?
        var i = 0
        func flush() {
            if !prose.isEmpty { segments.append(.markdown(prose.joined(separator: "\n"))) }
            prose = []
        }
        while i < lines.count {
            let line = lines[i]
            if let current = fence {
                if current.isClosed(by: line) { fence = nil }
            } else if let opened = Fence(opening: line) {
                fence = opened
            } else if let found = section(in: lines, at: i) {
                flush()
                segments.append(.details(found.section))
                i += found.lineCount
                if let trailing = found.trailing {
                    i -= 1
                    lines[i] = trailing
                }
                continue
            } else if line.range(of: #"^ {0,3}\[[^\]]+\]:\s*\S"#, options: .regularExpression) != nil {
                definitions.append(line.trimmingCharacters(in: .whitespaces))
            }
            prose.append(line)
            i += 1
        }
        flush()
        guard !definitions.isEmpty, segments.contains(where: { if case .details = $0 { true } else { false } })
        else { return segments }
        let suffix = "\n\n" + definitions.joined(separator: "\n")
        return segments.map {
            switch $0 {
            case .markdown(let text): .markdown(text + suffix)
            case .details(let s): .details(Section(summary: s.summary, isOpen: s.isOpen, body: s.body + suffix))
            }
        }
    }

    /// Four leading spaces, or a tab within them: the line is an indented code block's, or that block's
    /// continuation, never a tag.
    private static func isIndentedCode(_ line: some StringProtocol) -> Bool {
        var spaces = 0
        for character in line {
            if character == "\t" { return true }
            guard character == " " else { return false }
            spaces += 1
            if spaces == 4 { return true }
        }
        return false
    }

    private static func opening(_ trimmed: String) -> (isOpen: Bool, rest: Substring)? {
        guard let match = trimmed.prefixMatch(of: /<details(\s[^>]*)?>/.ignoresCase()) else { return nil }
        let attributes = match.1.map { String($0) } ?? ""
        let isOpen = attributes.range(of: #"(^|\s)open(\s|=|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return (isOpen, trimmed[match.range.upperBound...].drop { $0.isWhitespace })
    }

    /// The `<summary>` the section's first non-blank line opens, and the markdown after it.
    private static func summaryAndBody(_ inner: [String]) -> (String, String) {
        guard let first = inner.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let open = inner[first].trimmingCharacters(in: .whitespaces)
                  .prefixMatch(of: /<summary(\s[^>]*)?>/.ignoresCase())
        else { return (defaultSummary, inner.joined(separator: "\n")) }
        let firstLine = inner[first].trimmingCharacters(in: .whitespaces)
        var text = [String(firstLine[open.range.upperBound...])]
        var index = first
        var after: String?
        while true {
            if let close = text[text.count - 1].range(of: "</summary>", options: .caseInsensitive) {
                let line = text[text.count - 1]
                after = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                text[text.count - 1] = String(line[..<close.lowerBound])
                break
            }
            // A summary still streaming, or never closed, ends at the first blank line.
            guard index + 1 < inner.count, !inner[index + 1].trimmingCharacters(in: .whitespaces).isEmpty else { break }
            index += 1
            text.append(inner[index])
        }
        let body = (after.map { $0.isEmpty ? [] : [$0] } ?? []) + inner[(index + 1)...]
        return (plainSummary(text.joined(separator: " ")), body.joined(separator: "\n"))
    }

    /// The summary as inline markdown: `<code>` becomes backticks and other tags go.
    private static func plainSummary(_ html: String) -> String {
        let text = html
            .replacingOccurrences(of: #"</?code>"#, with: "`", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? defaultSummary : text
    }

    /// A code fence: up to three spaces, then three or more backticks or tildes.
    private struct Fence {
        let marker: Character
        let length: Int

        init?(opening line: String) {
            let text = line.drop { $0 == " " }
            guard line.count - text.count <= 3, let marker = text.first, marker == "`" || marker == "~" else { return nil }
            let length = text.prefix { $0 == marker }.count
            guard length >= 3 else { return nil }
            self.marker = marker
            self.length = length
        }

        func isClosed(by line: String) -> Bool {
            let text = line.drop { $0 == " " }
            guard line.count - text.count <= 3 else { return false }
            let run = text.prefix { $0 == marker }.count
            return run >= length && text.dropFirst(run).allSatisfy(\.isWhitespace)
        }
    }
}
