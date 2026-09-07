import Foundation

struct ParsedDiff: Equatable {
    var hunks: [Hunk]
    /// True when git's raw diff output reported `Binary files ... differ`
    /// instead of any renderable hunks. A file can be declared binary via
    /// `.gitattributes` (e.g. `*.dat binary`) even when its content happens
    /// to look like valid UTF-8 at the byte level — an on-disk content
    /// sniff alone would miss that case and treat a hunk-less result as a
    /// legitimate empty diff. Detected directly from the raw diff text here
    /// (before hunk parsing discards everything that isn't a `@@` line),
    /// rather than a separate git call.
    var isBinary: Bool = false
    /// Set when git reported a change with no renderable `@@` hunks AND no
    /// `Binary files ... differ` line either — a pure rename/copy (100%
    /// similarity, no content edits) or an executable-bit-only change.
    /// Without this, such a diff parses to empty `hunks`, indistinguishable
    /// from "nothing changed" even though the file IS listed as changed —
    /// the caller would otherwise report a misleading successful empty
    /// diff instead of surfacing what actually happened.
    var metadataSummary: String? = nil
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
        var isBinary = false
        var renameFrom: String?
        var renameTo: String?
        var copyFrom: String?
        var copyTo: String?
        var oldMode: String?
        var newMode: String?

        func flush() {
            if let c = current {
                hunks.append(ParsedDiff.Hunk(header: c.header, oldStart: c.oldStart,
                                              newStart: c.newStart, lines: c.lines))
            }
            current = nil
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("Binary files ") && line.hasSuffix(" differ") {
                isBinary = true
                continue
            }
            // Metadata-only lines (rename/copy pairing, executable-bit
            // change) only ever appear in the header section, before any
            // `@@` hunk — a content line with this exact text would still
            // carry a leading `+`/`-`/` ` prefix, so matching the bare
            // prefix here can't misfire on hunk content.
            if current == nil {
                if line.hasPrefix("rename from ") {
                    renameFrom = String(line.dropFirst("rename from ".count))
                    continue
                }
                if line.hasPrefix("rename to ") {
                    renameTo = String(line.dropFirst("rename to ".count))
                    continue
                }
                if line.hasPrefix("copy from ") {
                    copyFrom = String(line.dropFirst("copy from ".count))
                    continue
                }
                if line.hasPrefix("copy to ") {
                    copyTo = String(line.dropFirst("copy to ".count))
                    continue
                }
                if line.hasPrefix("old mode ") {
                    oldMode = String(line.dropFirst("old mode ".count))
                    continue
                }
                if line.hasPrefix("new mode ") {
                    newMode = String(line.dropFirst("new mode ".count))
                    continue
                }
            }
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
        // Only worth surfacing when there's nothing else to show — a rename
        // or mode change alongside real content edits already has hunks to
        // render, so the note would just be noise there.
        var metadataSummary: String?
        if hunks.isEmpty, !isBinary {
            if let renameFrom, let renameTo {
                metadataSummary = "Renamed from \(renameFrom) to \(renameTo) — no content changes."
            } else if let copyFrom, let copyTo {
                metadataSummary = "Copied from \(copyFrom) to \(copyTo) — no content changes."
            } else if let oldMode, let newMode {
                metadataSummary = "File mode changed from \(oldMode) to \(newMode) — no content changes."
            }
        }
        return ParsedDiff(hunks: hunks, isBinary: isBinary, metadataSummary: metadataSummary)
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
