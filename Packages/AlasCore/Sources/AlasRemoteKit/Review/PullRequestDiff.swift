import Foundation

/// A pull or merge request's raw unified diff as review entries, one per file.
public enum PullRequestDiff {
    /// The comment namespace the Mac files a provider review's comments under
    /// (`ReviewRequestDiffLoader.namespace(for:)`).
    public static func namespace(provider: String) -> String { provider == "gitlab" ? "gitlab-mr" : "github-pr" }

    /// `truncated`: the host cut the diff short, so the last file may be missing lines.
    public static func entries(raw: String, namespace: String, truncated: Bool = false) -> [ReviewEntry] {
        var sections: [[String]] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") { sections.append([]) }
            if !sections.isEmpty { sections[sections.count - 1].append(line) }
        }
        var entries = sections.compactMap { entry(lines: $0, namespace: namespace) }
        // The cut fell inside the last section; a binary or metadata-only one has no lines to lose.
        if truncated, case .hunks(let hunks, _)? = entries.last?.content {
            entries[entries.count - 1].content = .hunks(hunks, truncated: true)
        }
        return entries
    }

    private static func entry(lines: [String], namespace: String) -> ReviewEntry? {
        func value(_ prefix: String) -> String? {
            guard let raw = lines.first(where: { $0.hasPrefix(prefix) }).map({ String($0.dropFirst(prefix.count)) }) else { return nil }
            var index = raw.startIndex
            return GitQuotedPath.decode(in: raw, index: &index) ?? raw
        }
        let renameFrom = value("rename from "), renameTo = value("rename to ")
        let status = renameTo != nil ? "R" : lines.contains { $0.hasPrefix("new file mode ") } ? "A"
            : lines.contains { $0.hasPrefix("deleted file mode ") } ? "D" : "M"
        guard let path = renameTo ?? headerPath(lines[0]) else { return nil }
        let parsed = DiffParser.parse(lines.joined(separator: "\n"))
        let hunks = parsed.hunks.map { hunk in
            RemoteDiffHunk(header: hunk.header, oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hunk.lines.map {
                RemoteDiffLine(kind: $0.kind == .add ? "add" : $0.kind == .delete ? "delete" : "context", text: $0.text,
                               oldNumber: $0.oldNumber, newNumber: $0.newNumber, noTrailingNewline: $0.noTrailingNewline)
            })
        }
        let all = parsed.hunks.flatMap(\.lines)
        return ReviewEntry(
            id: ReviewEntryID(namespace: namespace, path: path), status: status,
            add: all.count { $0.kind == .add }, del: all.count { $0.kind == .delete }, renameFrom: renameFrom,
            // As a local diff: a rename or mode change with no lines shows its summary.
            content: parsed.isBinary ? .note("Binary file")
                : hunks.isEmpty && parsed.metadataSummary != nil ? .note(parsed.metadataSummary ?? "")
                : .hunks(hunks, truncated: false)
        )
    }

    /// The path of an unrenamed file's `diff --git a/P b/P` header (the new side's, when quoted).
    private static func headerPath(_ header: String) -> String? {
        let payload = String(header.dropFirst("diff --git ".count))
        var index = payload.startIndex
        if let old = GitQuotedPath.decode(in: payload, index: &index) {
            while index < payload.endIndex, payload[index] == " " { index = payload.index(after: index) }
            let new = GitQuotedPath.decode(in: payload, index: &index) ?? old
            return String(new.dropFirst(2))
        }
        // "a/P b/P": the two halves match, so P is what's left of the 5 fixed characters.
        guard payload.hasPrefix("a/"), payload.count >= 7, payload.count % 2 == 1 else { return nil }
        let length = (payload.count - 5) / 2
        return String(payload.dropFirst(2).prefix(length))
    }
}
