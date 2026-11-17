import Foundation

/// A line diff of two texts, shaped like `DiffParser`'s output of `git diff`, for a phone that
/// has the edit's old and new text but no git to ask.
public enum LineDiff {
    /// `old == nil` is a new file. Changes within `2 * context` lines of each other share a hunk.
    /// ponytail: a trailing newline is dropped on both sides, so a change to it alone shows no hunk.
    public static func parsedDiff(old: String?, new: String, context: Int = 3) -> ParsedDiff {
        let oldLines = lines(old ?? "")
        let newLines = lines(new)
        let difference = newLines.difference(from: oldLines)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // The edit script in order, each line with the 0-based old and new positions before it.
        typealias Op = (line: ParsedDiff.Hunk.Line, oldAt: Int, newAt: Int)
        var ops: [Op] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                ops.append((.init(kind: .delete, text: oldLines[i], oldNumber: i + 1, newNumber: nil), i, j))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                ops.append((.init(kind: .add, text: newLines[j], oldNumber: nil, newNumber: j + 1), i, j))
                j += 1
            } else {
                ops.append((.init(kind: .context, text: oldLines[i], oldNumber: i + 1, newNumber: j + 1), i, j))
                i += 1
                j += 1
            }
        }

        var ranges: [ClosedRange<Int>] = []
        for (index, op) in ops.enumerated() where op.line.kind != .context {
            let range = max(0, index - context)...min(ops.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...range.upperBound
            } else {
                ranges.append(range)
            }
        }

        let hunks = ranges.map { range in
            let slice = ops[range]
            let first = slice.first!
            let oldCount = slice.filter { $0.line.oldNumber != nil }.count
            let newCount = slice.filter { $0.line.newNumber != nil }.count
            // Git starts an empty side at the line before it, so a new file is `-0,0`.
            let oldStart = oldCount > 0 ? first.oldAt + 1 : first.oldAt
            let newStart = newCount > 0 ? first.newAt + 1 : first.newAt
            return ParsedDiff.Hunk(
                header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@",
                oldStart: oldStart, newStart: newStart, lines: slice.map(\.line))
        }
        return ParsedDiff(hunks: hunks)
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
