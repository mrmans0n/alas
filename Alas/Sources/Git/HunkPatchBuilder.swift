import Foundation

/// Builds a unified-diff patch for exactly one hunk. Pure — no I/O, no git.
/// Output is suitable for `git apply --cached` (stage) or `git apply --reverse`
/// (discard) when paired with the right `tracked` flag.
enum HunkPatchBuilder {
    static func patch(file: String, hunk: ParsedDiff.Hunk, tracked: Bool) -> String {
        let bodyLines = hunk.lines.map { line -> String in
            switch line.kind {
            case .add:     return "+\(line.text)"
            case .delete:  return "-\(line.text)"
            case .context: return " \(line.text)"
            }
        }
        let headerLines: [String]
        if tracked {
            headerLines = [
                "diff --git a/\(file) b/\(file)",
                "--- a/\(file)",
                "+++ b/\(file)",
                hunk.header,
            ]
        } else {
            headerLines = [
                "diff --git a/\(file) b/\(file)",
                "new file mode 100644",
                "--- /dev/null",
                "+++ b/\(file)",
                hunk.header,
            ]
        }
        return (headerLines + bodyLines).joined(separator: "\n") + "\n"
    }
}
