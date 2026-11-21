import Foundation

/// A line range picked in one hunk of one file; indexes are into `hunk.lines`.
public struct ReviewSelection: Equatable, Sendable {
    public let entry: ReviewEntryID
    public let hunk: Int
    public private(set) var start: Int
    public private(set) var end: Int
    /// The line the selection started on; extending spans from it to the new line.
    private let anchorLine: Int

    public init(entry: ReviewEntryID, hunk: Int, line: Int) {
        self.entry = entry
        self.hunk = hunk
        anchorLine = line
        start = line
        end = line
    }

    /// Spans from the first line to `line`, so a drag that comes back shrinks the range.
    /// Ignored for another hunk: a range never spans hunks.
    public mutating func extend(to line: Int, inHunk hunk: Int) {
        guard hunk == self.hunk else { return }
        start = min(anchorLine, line)
        end = max(anchorLine, line)
    }

    /// Added and context lines anchor to the new side, removed lines to the old one;
    /// a mixed range uses the new-side numbers of the lines it covers.
    public func anchor(in hunk: RemoteDiffHunk) -> RemoteReviewAnchor {
        let lines = hunk.lines[start...end]
        let new = lines.compactMap(\.newNumber)
        let (side, numbers) = new.isEmpty ? ("old", lines.compactMap(\.oldNumber)) : ("new", new)
        let first = numbers.min() ?? 0
        let last = numbers.max() ?? first
        return .line(side: side, startLine: first, endLine: last == first ? nil : last)
    }

    public func isValid(in hunks: [RemoteDiffHunk]) -> Bool {
        hunks.indices.contains(hunk) && hunks[hunk].lines.indices.contains(end)
    }

    public func quotedText(in hunk: RemoteDiffHunk) -> String {
        hunk.lines[start...end].map { line in
            (line.kind == "add" ? "+ " : line.kind == "delete" ? "- " : "  ") + line.text
        }.joined(separator: "\n")
    }
}
