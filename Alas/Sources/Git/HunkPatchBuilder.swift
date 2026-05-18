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
        // Quote a/<path> and b/<path> the way `git diff` does so paths with
        // tabs, quotes, backslashes, or control characters round-trip through
        // `git apply` correctly. Plain-ASCII paths come through unchanged.
        let aPath = quotedHeaderPath(prefix: "a/", file: file)
        let bPath = quotedHeaderPath(prefix: "b/", file: file)
        let headerLines: [String]
        if tracked {
            headerLines = [
                "diff --git \(aPath) \(bPath)",
                "--- \(aPath)",
                "+++ \(bPath)",
                hunk.header,
            ]
        } else {
            headerLines = [
                "diff --git \(aPath) \(bPath)",
                "new file mode \(untrackedMode)",
                "--- /dev/null",
                "+++ \(bPath)",
                hunk.header,
            ]
        }
        return (headerLines + bodyLines).joined(separator: "\n") + "\n"
    }

    /// Produce git's C-quoted path form for the patch header. Returns the raw
    /// `prefix + file` when no quoting is needed (plain ASCII, no specials);
    /// otherwise wraps the whole `prefix+file` string in double quotes and
    /// escapes per git's `quote_c_style` rules. Mirrors `git diff` output so
    /// `git apply` parses the path the same way it would parse a fresh diff.
    static func quotedHeaderPath(prefix: String, file: String) -> String {
        let combined = prefix + file
        if !needsQuoting(combined) { return combined }
        var out = "\""
        for byte in combined.utf8 {
            switch byte {
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x09: out += "\\t"
            case 0x0a: out += "\\n"
            case 0x0b: out += "\\v"
            case 0x0c: out += "\\f"
            case 0x0d: out += "\\r"
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            default:
                if byte < 0x20 || byte == 0x7f || byte >= 0x80 {
                    out += String(format: "\\%03o", byte)
                } else {
                    out.append(Character(UnicodeScalar(byte)))
                }
            }
        }
        out += "\""
        return out
    }

    private static func needsQuoting(_ path: String) -> Bool {
        for byte in path.utf8 {
            if byte < 0x20 || byte == 0x7f { return true }
            if byte == 0x22 || byte == 0x5c { return true } // " and \
            if byte >= 0x80 { return true } // non-ASCII → git quotes by default
        }
        return false
    }
}
