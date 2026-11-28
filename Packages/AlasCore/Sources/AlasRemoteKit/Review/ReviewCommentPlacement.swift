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

/// Where a comment's quoted lines sit now, on its side of a file's diff.
public enum ReviewQuoteLocation: Equatable, Sendable {
    /// No usable quote: place it by its line numbers.
    case byNumber
    /// Its anchor's lines still read the quote.
    case atAnchor
    /// The one run of lines that reads the quote, now that its anchor doesn't.
    case moved(ClosedRange<Int>)
    /// No run reads the quote, or several do: Outdated.
    case lost
}

/// One side's numbered lines of a file's diff, in diff order, to find comments' quotes in.
public struct ReviewQuotedLines: Sendable {
    private var numbers: [Int] = []
    private var texts: [Substring] = []
    private var index: [Int: Int] = [:]

    public init() {}

    public mutating func append(number: Int, text: String) {
        index[number] = numbers.count
        numbers.append(number)
        texts.append(Self.trimmed(text[...]))
    }

    /// A comment on `start...end` that quotes `quoted` follows its lines: at its anchor while the lines there
    /// still read the same, else at the one run of consecutive lines that does. A quote that doesn't span
    /// the anchor's lines (the Mac quotes every row of a mixed selection, deleted and context ones included)
    /// places by line numbers.
    public func locate(start: Int, end: Int, quoted: String?) -> ReviewQuoteLocation {
        guard let quoted else { return .byNumber }
        let span = end - start + 1
        var quotedLines = quoted.split(separator: "\n", omittingEmptySubsequences: false)
        // A blank last line counts while the quote spans its lines; past that it's the newline the Mac trims.
        while quotedLines.count > span, quotedLines.last?.isEmpty == true { quotedLines.removeLast() }
        let wanted = quotedLines.map(Self.trimmed)
        guard wanted.count == span, wanted.contains(where: { !$0.isEmpty }) else { return .byNumber }
        // Whether the lines from `i` on are consecutive and read `wanted`.
        func reads(at i: Int) -> Bool {
            i + wanted.count <= numbers.count && wanted.indices.allSatisfy { k in
                texts[i + k] == wanted[k] && numbers[i + k] == numbers[i] + k
            }
        }
        if let here = index[start], reads(at: here) { return .atAnchor }
        let runs = numbers.indices.filter(reads)
        guard runs.count == 1, let i = runs.first else { return .lost }
        return .moved(numbers[i]...numbers[i + wanted.count - 1])
    }

    private static func trimmed(_ text: Substring) -> Substring {
        text[..<(text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? text.startIndex)]
    }
}

public enum ReviewCommentPlacement {
    /// Row index (into `ReviewLayout.rows(for:folded:false)`) after which each comment goes, in input order;
    /// nil = top of file, shown as Outdated. A comment that quotes its lines follows them
    /// (`ReviewQuotedLines.locate`).
    public static func place(_ items: [ReviewPlaceable], in hunks: [RemoteDiffHunk]) -> [ReviewPlacedComment] {
        // Each side's numbered lines, and the row each line number is.
        var newLines = ReviewQuotedLines(), oldLines = ReviewQuotedLines()
        var newRows: [Int: Int] = [:], oldRows: [Int: Int] = [:]
        var row = 0
        for hunk in hunks {
            row += 1
            for line in hunk.lines {
                if let number = line.newNumber {
                    newLines.append(number: number, text: line.text)
                    newRows[number] = row
                }
                if let number = line.oldNumber {
                    oldLines.append(number: number, text: line.text)
                    oldRows[number] = row
                }
                row += 1
            }
        }
        return items.map { item in
            guard let side = item.side, let start = item.line else { return ReviewPlacedComment(id: item.id, row: nil) }
            let end = item.endLine ?? start
            let rows = side == "new" ? newRows : oldRows
            let byNumber = ReviewPlacedComment(id: item.id, row: rows[end])
            guard side == "new" || side == "old" else { return byNumber }
            switch (side == "new" ? newLines : oldLines).locate(start: start, end: end, quoted: item.selectedText) {
            case .byNumber, .atAnchor: return byNumber
            case .moved(let lines): return ReviewPlacedComment(id: item.id, row: rows[lines.upperBound], movedTo: lines)
            case .lost: return ReviewPlacedComment(id: item.id, row: nil)
            }
        }
    }
}
