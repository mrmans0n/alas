import Foundation

/// Path validation and payload caps for the remote changes/files surface.
///
/// Every path here arrives from a paired device, so containment is enforced on
/// the resolved (symlink-followed) path, not the string. `.git` is excluded
/// entirely: a worktree's git config can hold remote URLs with embedded
/// credentials.
enum RemoteWorktreeFileAccess {
    static let maxFileBytes = 512 * 1024
    static let maxDiffLines = 2_000
    static let maxChangedFiles = 500

    /// Returns the on-disk URL for a worktree-relative path, or nil when the
    /// path is empty, absolute, traverses upward, names `.git`, or resolves
    /// outside the worktree through a symlink.
    static func resolve(path: String, in worktreeRoot: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }
        guard !components.contains(".."), !components.contains(".git") else { return nil }

        let candidate = components.reduce(worktreeRoot) { $0.appendingPathComponent($1) }
        let resolvedRoot = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(rootPath) else { return nil }

        // Check that no component of the resolved path is .git (case-insensitive),
        // including via symlink aliases or case variations. This is the actual
        // security boundary: we check the canonical (symlink-resolved) path,
        // not just the user's input string.
        let resolvedRelativePath = String(resolved.path.dropFirst(rootPath.count))
        let resolvedComponents = resolvedRelativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !resolvedComponents.contains(where: { $0.lowercased() == ".git" }) else { return nil }

        return candidate
    }

    /// Caps a diff at `maxDiffLines` total lines, dropping whole trailing
    /// lines from the hunk that crosses the cap. Reports whether anything was
    /// dropped so the client can render a truncation footer.
    static func truncateHunks(_ hunks: [ParsedDiff.Hunk]) -> (hunks: [ParsedDiff.Hunk], truncated: Bool) {
        var remaining = maxDiffLines
        var kept: [ParsedDiff.Hunk] = []
        for hunk in hunks {
            if remaining <= 0 { return (kept, true) }
            if hunk.lines.count <= remaining {
                kept.append(hunk)
                remaining -= hunk.lines.count
                continue
            }
            kept.append(ParsedDiff.Hunk(
                header: hunk.header,
                oldStart: hunk.oldStart,
                newStart: hunk.newStart,
                lines: Array(hunk.lines.prefix(remaining))))
            return (kept, true)
        }
        return (kept, false)
    }

    /// Caps a change list at `maxChangedFiles` entries.
    static func truncateFiles(_ files: [ChangedFile]) -> (files: [ChangedFile], truncated: Bool) {
        guard files.count > maxChangedFiles else { return (files, false) }
        return (Array(files.prefix(maxChangedFiles)), true)
    }
}
