import Foundation

public enum HighlightChunks {
    /// Splits `source` into runs of `linesPerChunk` lines, each with the spans that touch it
    /// clipped to the run and rebased to its UTF-16 start. A span crossing a boundary lands in
    /// both runs. Empty source gives one empty run.
    public static func split(source: String, spans: [HighlightSpan], linesPerChunk: Int) -> [(text: String, spans: [HighlightSpan])] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var start = 0
        return stride(from: 0, to: lines.count, by: linesPerChunk).map { first in
            let text = lines[first ..< min(first + linesPerChunk, lines.count)].joined(separator: "\n")
            let end = start + text.utf16.count
            let clipped = spans.compactMap { span -> HighlightSpan? in
                let lower = max(span.range.location, start), upper = min(NSMaxRange(span.range), end)
                guard lower < upper else { return nil }
                return HighlightSpan(range: NSRange(location: lower - start, length: upper - lower), capture: span.capture)
            }
            start = end + 1 // the newline between runs
            return (text, clipped)
        }
    }
}
