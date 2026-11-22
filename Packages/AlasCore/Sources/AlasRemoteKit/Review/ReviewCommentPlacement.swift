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
    public static func place(_ items: [ReviewPlaceable], in hunks: [RemoteDiffHunk]) -> [ReviewPlacedComment] {
        // Each side's numbered lines in diff order, with the row each one is.
        var newLines: [(number: Int, text: Substring, row: Int)] = []
        var oldLines: [(number: Int, text: Substring, row: Int)] = []
        var row = 0
        for hunk in hunks {
            row += 1
            for line in hunk.lines {
                if let number = line.newNumber { newLines.append((number, trimmed(line.text[...]), row)) }
                if let number = line.oldNumber { oldLines.append((number, trimmed(line.text[...]), row)) }
                row += 1
            }
        }
        return items.map { item in
            guard let side = item.side, let start = item.line else { return ReviewPlacedComment(id: item.id, row: nil) }
            let end = item.endLine ?? start
            let all = side == "new" ? newLines : oldLines
            guard let quoted = item.selectedText, side == "new" || side == "old",
                  !quoted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ReviewPlacedComment(id: item.id, row: all.first { $0.number == end }?.row)
            }
            let wanted = quoted.split(separator: "\n", omittingEmptySubsequences: false).map(trimmed)
            // Runs of consecutive line numbers reading `wanted`, as the index of their first line.
            let runs = all.indices.filter { i in
                i + wanted.count <= all.count && wanted.indices.allSatisfy { k in
                    all[i + k].text == wanted[k] && all[i + k].number == all[i].number + k
                }
            }
            if let here = runs.first(where: { all[$0].number == start && all[$0 + wanted.count - 1].number == end }) {
                return ReviewPlacedComment(id: item.id, row: all[here + wanted.count - 1].row)
            }
            guard runs.count == 1, let first = runs.first.map({ all[$0] }), let last = runs.first.map({ all[$0 + wanted.count - 1] }) else {
                return ReviewPlacedComment(id: item.id, row: nil)
            }
            return ReviewPlacedComment(id: item.id, row: last.row, movedTo: first.number...last.number)
        }
    }

    private static func trimmed(_ text: Substring) -> Substring {
        text[..<(text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? text.startIndex)]
    }
}
