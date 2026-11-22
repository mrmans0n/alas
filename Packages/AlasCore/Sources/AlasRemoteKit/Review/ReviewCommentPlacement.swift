import Foundation

public struct ReviewPlaceable: Equatable, Sendable {
    public let id: String
    public let side: String?
    public let line: Int?
    public let endLine: Int?
    /// The lines the comment was written on, "\n"-joined; nil places it by line numbers alone.
    public let selectedText: String?

    public init(id: String, side: String?, line: Int?, endLine: Int?, selectedText: String? = nil) {
        self.id = id
        self.side = side
        self.line = line
        self.endLine = endLine
        self.selectedText = selectedText
    }
}

public struct ReviewPlacedComment: Equatable, Sendable {
    public let id: String
    public let row: Int?
    /// The lines it now sits on when its code moved away from its anchor; nil when it stayed.
    public let movedTo: ClosedRange<Int>?

    public init(id: String, row: Int?, movedTo: ClosedRange<Int>? = nil) {
        self.id = id
        self.row = row
        self.movedTo = movedTo
    }
}

public enum ReviewCommentPlacement {
    /// Row index (into `ReviewLayout.rows(for:folded:false)`) after which each comment goes, in input order;
    /// nil = top of file, shown as Outdated.
    ///
    /// A comment that quotes its lines follows them: placed at its anchor while the lines there still read
    /// the same, else at the one run of lines on that side that does; with none, or several, it is Outdated.
    /// A quote that doesn't span its anchor's lines (the Mac quotes every row of a mixed selection, deleted
    /// and context ones included) places by line numbers.
    public static func place(_ items: [ReviewPlaceable], in hunks: [RemoteDiffHunk]) -> [ReviewPlacedComment] {
        typealias Line = (number: Int, text: Substring, row: Int)
        // Each side's numbered lines in diff order, with the row each one is, and where each number sits.
        var newLines: [Line] = [], oldLines: [Line] = []
        var newIndex: [Int: Int] = [:], oldIndex: [Int: Int] = [:]
        var row = 0
        for hunk in hunks {
            row += 1
            for line in hunk.lines {
                if let number = line.newNumber {
                    newIndex[number] = newLines.count
                    newLines.append((number, trimmed(line.text[...]), row))
                }
                if let number = line.oldNumber {
                    oldIndex[number] = oldLines.count
                    oldLines.append((number, trimmed(line.text[...]), row))
                }
                row += 1
            }
        }
        return items.map { item in
            guard let side = item.side, let start = item.line else { return ReviewPlacedComment(id: item.id, row: nil) }
            let end = item.endLine ?? start
            let (all, index) = side == "new" ? (newLines, newIndex) : (oldLines, oldIndex)
            let byNumber = ReviewPlacedComment(id: item.id, row: index[end].map { all[$0].row })
            guard let quoted = item.selectedText, side == "new" || side == "old" else { return byNumber }
            let span = end - start + 1
            var quotedLines = quoted.split(separator: "\n", omittingEmptySubsequences: false)
            // A blank last line counts while the quote spans its lines; past that it's the newline the Mac trims.
            while quotedLines.count > span, quotedLines.last?.isEmpty == true { quotedLines.removeLast() }
            let wanted = quotedLines.map(trimmed)
            guard wanted.count == span, wanted.contains(where: { !$0.isEmpty }) else { return byNumber }
            // Whether the lines from `all[i]` on are consecutive and read `wanted`.
            func reads(at i: Int) -> Bool {
                i + wanted.count <= all.count && wanted.indices.allSatisfy { k in
                    all[i + k].text == wanted[k] && all[i + k].number == all[i].number + k
                }
            }
            if let here = index[start], reads(at: here) { return ReviewPlacedComment(id: item.id, row: all[here + wanted.count - 1].row) }
            let runs = all.indices.filter(reads)
            guard runs.count == 1, let i = runs.first else { return ReviewPlacedComment(id: item.id, row: nil) }
            let last = all[i + wanted.count - 1]
            return ReviewPlacedComment(id: item.id, row: last.row, movedTo: all[i].number...last.number)
        }
    }

    private static func trimmed(_ text: Substring) -> Substring {
        text[..<(text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? text.startIndex)]
    }
}
