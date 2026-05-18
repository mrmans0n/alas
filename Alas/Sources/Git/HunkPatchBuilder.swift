import Foundation

/// Builds a unified-diff patch for exactly one hunk. Pure — no I/O, no git.
/// Output is suitable for `git apply --cached` (stage) or `git apply --reverse`
/// (discard) when paired with the right `tracked` flag.
enum HunkPatchBuilder {
    /// Git's mode string for a regular non-executable file. Used as the
    /// default `untrackedMode` when the caller doesn't know the source
    /// file's actual mode. Real callers staging from disk should probe
    /// the file (executable bit / symlink) and pass the right value so
    /// `git apply --cached` doesn't drop +x or turn a symlink into a regular
    /// file.
    static let defaultUntrackedMode = "100644"

    static func patch(
        file: String,
        hunk: ParsedDiff.Hunk,
        tracked: Bool,
        untrackedMode: String = defaultUntrackedMode
    ) -> String {
        var bodyLines: [String] = []
        for line in hunk.lines {
            let sigil: String
            switch line.kind {
            case .add:     sigil = "+"
            case .delete:  sigil = "-"
            case .context: sigil = " "
            }
            bodyLines.append("\(sigil)\(line.text)")
            // EOF without trailing newline: re-emit the sentinel so
            // `git apply` accepts the patch against the original worktree.
            if line.noTrailingNewline {
                bodyLines.append("\\ No newline at end of file")
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
                "new file mode \(untrackedMode)",
                "--- /dev/null",
                "+++ b/\(file)",
                hunk.header,
            ]
        }
        return (headerLines + bodyLines).joined(separator: "\n") + "\n"
    }
}
