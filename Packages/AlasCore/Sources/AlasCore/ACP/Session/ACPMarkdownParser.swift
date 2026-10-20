import Foundation

/// Splits chat markdown into the blocks `ACPMarkdownText` renders.
public enum ACPMarkdownParser: Sendable {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case taskList([TaskItem])
        case quote(String)
        case code(language: String?, body: String)
        case streamingCode(language: String?, body: String)
        case mermaid(source: String)
        case image(alt: String, source: String)
        case table(header: [String], rows: [[String]])
    }

    public struct TaskItem: Equatable, Sendable {
        public let isChecked: Bool
        public let text: String

        public init(isChecked: Bool, text: String) {
            self.isChecked = isChecked
            self.text = text
        }
    }

    /// Detect a GitHub-flavoured markdown table starting at `start`:
    ///   | h1 | h2 |
    ///   |----|----|
    ///   | a  | b  |
    /// Returns header cells + body rows + number of consumed lines, or nil.
    private static func matchTable(from lines: [String], at start: Int) -> ([String], [[String]], Int)? {
        guard start + 1 < lines.count else { return nil }
        let head = lines[start].trimmingCharacters(in: .whitespaces)
        let sep = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard head.contains("|"), sep.contains("|"),
              sep.allSatisfy({ "|-: ".contains($0) }),
              sep.contains("-")
        else { return nil }
        let header = splitTableRow(head)
        let columnCount = header.count
        guard columnCount > 0 else { return nil }
        var rows: [[String]] = []
        var j = start + 2
        while j < lines.count {
            let row = lines[j].trimmingCharacters(in: .whitespaces)
            guard row.contains("|"), !row.isEmpty else { break }
            var cells = splitTableRow(row)
            // Normalise width to header length.
            if cells.count < columnCount {
                cells += Array(repeating: "", count: columnCount - cells.count)
            } else if cells.count > columnCount {
                cells = Array(cells.prefix(columnCount))
            }
            rows.append(cells)
            j += 1
        }
        return (header, rows, j - start)
    }

    private static func splitTableRow(_ raw: String) -> [String] {
        var s = raw
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Detect `# Heading` / `## Subheading` etc. (1–6 `#`s, then whitespace,
    /// then content). Returns `(level, text)` or nil.
    private static func matchHeading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1, idx < line.endIndex, line[idx].isWhitespace else { return nil }
        let body = line[idx...].drop(while: { $0.isWhitespace })
        guard !body.isEmpty else { return nil }
        return (level, String(body))
    }

    private struct FenceDelimiter {
        let marker: Character
        let length: Int
        let language: String?

        public init(marker: Character, length: Int, language: String?) {
            self.marker = marker
            self.length = length
            self.language = language
        }
    }

    private static func matchFence(_ line: String) -> FenceDelimiter? {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return nil }
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let fenceText = line[index...]
        guard let marker = fenceText.first, marker == "`" || marker == "~" else { return nil }
        let length = fenceText.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let language = fenceText.dropFirst(length).trimmingCharacters(in: .whitespaces)
        return FenceDelimiter(marker: marker, length: length, language: language.isEmpty ? nil : language)
    }

    private static func closesFence(_ line: String, _ openingFence: FenceDelimiter) -> Bool {
        var index = line.startIndex
        var leadingSpaces = 0
        while index < line.endIndex, line[index] == " " {
            leadingSpaces += 1
            guard leadingSpaces <= 3 else { return false }
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == openingFence.marker else { return false }
        let markerCount = line[index...].prefix(while: { $0 == openingFence.marker }).count
        guard markerCount >= openingFence.length else { return false }
        let afterMarker = line.index(index, offsetBy: markerCount)
        return line[afterMarker...].allSatisfy(\.isWhitespace)
    }

    /// A line that is nothing but `![alt](source)`, optionally with a
    /// `"title"` or a `<bracketed source>`. Images mid-sentence stay inline.
    private static func matchImage(_ line: String) -> (alt: String, source: String)? {
        guard let match = line.wholeMatch(of: /!\[([^\]]*)\]\((<[^>]*>[^)]*|[^)<][^)]*)\)/) else { return nil }
        var source = match.2.trimmingCharacters(in: .whitespaces)
        if source.hasSuffix("\""), let quote = source.dropLast().lastIndex(of: "\""),
           quote > source.startIndex, source[source.index(before: quote)] == " " {
            source = source[..<quote].trimmingCharacters(in: .whitespaces)
        }
        if source.hasPrefix("<"), source.hasSuffix(">") {
            source = String(source.dropFirst().dropLast())
        }
        guard !source.isEmpty else { return nil }
        return (String(match.1), source)
    }

    private static func matchTaskItem(_ line: String) -> TaskItem? {
        guard line.count >= 5 else { return nil }
        let marker = String(line.prefix(5))
        let isChecked: Bool
        switch marker {
        case "- [ ]": isChecked = false
        case "- [x]", "- [X]": isChecked = true
        default: return nil
        }

        let remainder = line.dropFirst(5)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        return TaskItem(
            isChecked: isChecked,
            text: String(remainder.drop(while: \.isWhitespace))
        )
    }

    private static func startsParagraphBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || matchFence(line) != nil || trimmed.hasPrefix(">")
            || matchHeading(trimmed) != nil || matchTaskItem(line) != nil || matchImage(trimmed) != nil
    }

    private static func inlineBlockEnd(in lines: [Substring], at start: Int) -> String.Index {
        let first = String(lines[start])
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        // Headings, task items and standalone images are rendered separately.
        if matchHeading(trimmed) != nil || matchTaskItem(first) != nil || matchImage(trimmed) != nil {
            return lines[start].endIndex
        }
        let isQuote = trimmed.hasPrefix(">")
        var end = start
        while end + 1 < lines.count {
            let next = String(lines[end + 1])
            if isQuote {
                if !next.trimmingCharacters(in: .whitespaces).hasPrefix(">") { break }
            } else if startsParagraphBoundary(next) {
                break
            }
            end += 1
        }
        return lines[end].endIndex
    }

    /// Display-only filtering for review bodies. Code literals retain HTML comments.
    public static func hidingHTMLComments(_ text: String) -> String {
        guard text.contains("<!--") else { return text }
        var fence: FenceDelimiter?
        var inComment = false
        var codeEnd: String.Index?
        var result: [String] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineNumber, line) in lines.enumerated() {
            if let opening = fence {
                result.append(String(line))
                if closesFence(String(line), opening) { fence = nil }
                continue
            }
            if !inComment, codeEnd == nil, let opening = matchFence(String(line)) {
                fence = opening
                result.append(String(line))
                continue
            }
            var visible = ""
            var index = line.startIndex
            while index < line.endIndex {
                if let end = codeEnd {
                    let visibleEnd = min(end, line.endIndex)
                    visible += line[index..<visibleEnd]
                    index = visibleEnd
                    if index == end { codeEnd = nil }
                } else if inComment {
                    guard let end = line[index...].range(of: "-->") else { break }
                    index = end.upperBound
                    inComment = false
                } else if line[index...].hasPrefix("<!--") {
                    inComment = true
                    index = line.index(index, offsetBy: 4)
                } else if line[index] == "\\" {
                    visible.append(line[index])
                    index = line.index(after: index)
                    if index < line.endIndex {
                        visible.append(line[index])
                        index = line.index(after: index)
                    }
                } else if line[index] == "`" {
                    let run = line[index...].prefix(while: { $0 == "`" })
                    let afterRun = line.index(index, offsetBy: run.count)
                    let limit = inlineBlockEnd(in: lines, at: lineNumber)
                    var search = afterRun
                    var closing: String.Index?
                    while search < limit {
                        guard let tick = text[search..<limit].firstIndex(of: "`") else { break }
                        let count = text[tick...].prefix(while: { $0 == "`" }).count
                        search = text.index(tick, offsetBy: count)
                        if count == run.count { closing = search; break }
                    }
                    if let closing {
                        codeEnd = closing
                    } else {
                        visible += line[index..<afterRun]
                        index = afterRun
                    }
                } else {
                    visible.append(line[index])
                    index = line.index(after: index)
                }
            }
            result.append(visible)
        }
        return result.joined(separator: "\n")
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        let lines = text.components(separatedBy: "\n")

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if let fence = matchFence(line) {
                i += 1
                var body: [String] = []
                while i < lines.count, !closesFence(lines[i], fence) {
                    body.append(lines[i])
                    i += 1
                }
                let closesBeforeEnd = i < lines.count
                if closesBeforeEnd { i += 1 } // skip closing fence
                let codeBody = body.joined(separator: "\n")
                if closesBeforeEnd {
                    let hasRenderableCode = !codeBody
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                    if MermaidFence.isMermaid(language: fence.language), hasRenderableCode {
                        blocks.append(.mermaid(source: codeBody))
                    } else {
                        blocks.append(.code(language: fence.language, body: codeBody))
                    }
                } else {
                    blocks.append(.streamingCode(language: fence.language, body: codeBody))
                }
                continue
            }

            // Heading.
            if let (level, headingText) = matchHeading(trimmed) {
                blocks.append(.heading(level: level, text: headingText))
                i += 1
                continue
            }

            // Markdown table: a header row + separator (---|:--:|---) + body rows.
            if let (header, rows, consumed) = matchTable(from: lines, at: i) {
                blocks.append(.table(header: header, rows: rows))
                i += consumed
                continue
            }

            // Blockquote: collect contiguous `> ` prefixed lines.
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var s = lines[i].trimmingCharacters(in: .whitespaces)
                    s.removeFirst()
                    if s.first == " " { s.removeFirst() }
                    quoted.append(s)
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            // Blank line — paragraph boundary.
            if trimmed.isEmpty {
                i += 1
                continue
            }

            if let (alt, source) = matchImage(trimmed) {
                blocks.append(.image(alt: alt, source: source))
                i += 1
                continue
            }

            // Task list: collect contiguous top-level GitHub-style items.
            if let task = matchTaskItem(line) {
                var items = [task]
                i += 1
                while i < lines.count, let task = matchTaskItem(lines[i]) {
                    items.append(task)
                    i += 1
                }
                blocks.append(.taskList(items))
                continue
            }

            // Paragraph: collect until blank or block-start.
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                if startsParagraphBoundary(lines[i]) { break }
                para.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }
        return blocks
    }
}
