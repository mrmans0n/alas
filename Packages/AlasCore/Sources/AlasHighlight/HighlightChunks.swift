import Foundation

public enum HighlightChunks {
    /// Splits `source` into runs of `linesPerChunk` lines, each with the spans that touch it
    /// clipped to the run and rebased to its UTF-16 start. A span crossing a boundary lands in
    /// both runs. Empty source gives one empty run.
    public static func split(source: String, spans: [HighlightSpan], linesPerChunk: Int) -> [(text: String, spans: [HighlightSpan])] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var chunks: [(text: String, start: Int, end: Int, spans: [HighlightSpan])] = []
        var start = 0
        for first in stride(from: 0, to: lines.count, by: linesPerChunk) {
            let text = lines[first ..< min(first + linesPerChunk, lines.count)].joined(separator: "\n")
            let end = start + text.utf16.count
            chunks.append((text, start, end, []))
            start = end + 1 // the newline between runs
        }
        // Spans sorted by start only ever move the first candidate run forward: linear overall.
        var first = 0
        // Stable, so overlapping spans keep the highlighter's paint order.
        let sorted = spans.enumerated().sorted {
            ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset)
        }.map(\.element)
        for span in sorted {
            let lower = span.range.location, upper = NSMaxRange(span.range)
            while first + 1 < chunks.count, chunks[first + 1].start <= lower {
                first += 1
            }
            var index = first
            while index < chunks.count, chunks[index].start < upper {
                let chunk = chunks[index]
                let clippedLower = max(lower, chunk.start), clippedUpper = min(upper, chunk.end)
                if clippedLower < clippedUpper {
                    chunks[index].spans.append(HighlightSpan(
                        range: NSRange(location: clippedLower - chunk.start, length: clippedUpper - clippedLower),
                        capture: span.capture
                    ))
                }
                index += 1
            }
        }
        return chunks.map { ($0.text, $0.spans) }
    }
}

public enum CodeFence {
    /// Whether a code block's source lines (opener through last line) end in a fence that closes
    /// it: same character, at least as long. A still-streaming block runs to the end of the
    /// document with no closer. Indented blocks have no fence, so they are always closed.
    public static func isClosed(_ lines: [Substring]) -> Bool {
        guard let first = lines.first, let (char, count) = fence(first) else { return true }
        guard lines.count > 1, let (closeChar, closeCount) = fence(lines[lines.count - 1]) else { return false }
        let closer = lines[lines.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return closeChar == char && closeCount >= count && closer.count == closeCount
    }

    private static func fence(_ line: Substring) -> (Character, Int)? {
        let trimmed = line.drop { $0 == " " }
        guard let char = trimmed.first, char == "`" || char == "~" else { return nil }
        let count = trimmed.prefix { $0 == char }.count
        return count >= 3 ? (char, count) : nil
    }
}
