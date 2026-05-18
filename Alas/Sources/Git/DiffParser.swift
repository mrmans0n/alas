import Foundation

struct ParsedDiff: Equatable {
    var hunks: [Hunk]
    struct Hunk: Equatable {
        let header: String          // raw "@@ ... @@" line
        let oldStart: Int
        let newStart: Int
        let lines: [Line]
        struct Line: Equatable {
            enum Kind { case context, add, delete }
            let kind: Kind
            let text: String        // without the leading + - or space
            let oldNumber: Int?
            let newNumber: Int?
            /// True when the source diff carried a `\ No newline at end of file`
            /// sentinel after this line. Patch builders must re-emit the
            /// sentinel; otherwise `git apply` rejects the patch because the
            /// content doesn't match the worktree.
            var noTrailingNewline: Bool = false
        }
    }
}

enum DiffParser {
    static func parse(_ raw: String) -> ParsedDiff {
        var hunks: [ParsedDiff.Hunk] = []
        var current: (header: String, oldStart: Int, newStart: Int, lines: [ParsedDiff.Hunk.Line])? = nil
        var oldCounter = 0
        var newCounter = 0

        func flush() {
            if let c = current {
                hunks.append(ParsedDiff.Hunk(header: c.header, oldStart: c.oldStart,
                                              newStart: c.newStart, lines: c.lines))
            }
            current = nil
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@") {
                flush()
                let (oldStart, newStart) = parseHunkHeader(line)
                current = (header: line, oldStart: oldStart, newStart: newStart, lines: [])
                oldCounter = oldStart
                newCounter = newStart
                continue
            }
            guard current != nil else { continue }
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                let text = String(line.dropFirst())
                current!.lines.append(.init(kind: .add, text: text, oldNumber: nil, newNumber: newCounter))
                newCounter += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                let text = String(line.dropFirst())
                current!.lines.append(.init(kind: .delete, text: text, oldNumber: oldCounter, newNumber: nil))
                oldCounter += 1
            } else if line.hasPrefix(" ") {
                let text = String(line.dropFirst())
                current!.lines.append(.init(kind: .context, text: text, oldNumber: oldCounter, newNumber: newCounter))
                oldCounter += 1
                newCounter += 1
            } else if line.hasPrefix("\\ No newline at end of file") {
                // The sentinel follows whichever line (`+`, `-`, or ` `) lacks
                // a trailing newline at EOF. Mark the previously-appended line
                // so HunkPatchBuilder can re-emit the marker — without it,
                // `git apply --reverse` rejects the patch.
                if let lastIdx = current?.lines.indices.last {
                    current!.lines[lastIdx].noTrailingNewline = true
                }
            }
        }
        flush()
        return ParsedDiff(hunks: hunks)
    }

    private static func parseHunkHeader(_ header: String) -> (Int, Int) {
        // @@ -10,3 +10,4 @@ ...
        let parts = header.split(separator: " ")
        guard parts.count >= 3 else { return (1, 1) }
        let oldRange = String(parts[1].dropFirst())   // -10,3 → 10,3
        let newRange = String(parts[2].dropFirst())   // +10,4 → 10,4
        let oldStart = Int(oldRange.split(separator: ",").first ?? "1") ?? 1
        let newStart = Int(newRange.split(separator: ",").first ?? "1") ?? 1
        return (oldStart, newStart)
    }
}
