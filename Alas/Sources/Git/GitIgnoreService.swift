import Foundation

enum IgnoreDestination {
    case repoRoot
    case nearest
    case infoExclude
}

enum GitIgnoreService {
    /// Append a gitignore pattern for `entryPath` to `destination`.
    /// `entryPath` is repo-relative (POSIX `/` separators).
    /// Returns the file written to. Idempotent: if the pattern already
    /// exists in the destination, returns the URL without modifying it.
    ///
    /// `infoExcludeURL` overrides the destination URL when
    /// `destination == .infoExclude`. Linked worktrees store
    /// `info/exclude` outside the working tree (in the per-worktree git
    /// dir under `.git/worktrees/<name>/info/exclude`), so callers
    /// managing worktrees should resolve the path via
    /// `git rev-parse --git-path info/exclude` and pass the result here.
    /// When `nil`, the service falls back to `repoURL/.git/info/exclude`
    /// — correct for primary worktrees only.
    static func appendIgnore(
        entryPath: String,
        isDirectory: Bool,
        destination: IgnoreDestination,
        repoURL: URL,
        infoExcludeURL: URL? = nil
    ) throws -> URL {
        let target = try resolveTarget(
            destination: destination,
            repoURL: repoURL,
            entryPath: entryPath,
            infoExcludeURL: infoExcludeURL
        )
        let pattern = computePattern(
            entryPath: entryPath,
            isDirectory: isDirectory,
            targetFile: target,
            repoURL: repoURL
        )
        try appendPatternIfMissing(pattern, to: target)
        return target
    }

    // MARK: - Internals

    private static func resolveTarget(
        destination: IgnoreDestination,
        repoURL: URL,
        entryPath: String,
        infoExcludeURL: URL?
    ) throws -> URL {
        let fm = FileManager.default
        switch destination {
        case .repoRoot:
            return repoURL.appendingPathComponent(".gitignore")
        case .infoExclude:
            if let infoExcludeURL { return infoExcludeURL }
            return repoURL
                .appendingPathComponent(".git")
                .appendingPathComponent("info")
                .appendingPathComponent("exclude")
        case .nearest:
            // Walk up from the entry's parent directory toward the repo root,
            // using the first existing .gitignore. If none exist, fall back
            // to creating one at the entry's own parent directory.
            let entryParent = entryParentRelative(entryPath: entryPath)
            var current = entryParent
            while true {
                let candidate = repoURL
                    .appending(pathComponentsFromRepoRelative: current)
                    .appendingPathComponent(".gitignore")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
                if current.isEmpty { break }
                current = parentRepoRelative(current)
            }
            // No existing .gitignore anywhere — create one at the entry's
            // own parent directory (most-local scope).
            return repoURL
                .appending(pathComponentsFromRepoRelative: entryParent)
                .appendingPathComponent(".gitignore")
        }
    }

    private static func computePattern(
        entryPath: String,
        isDirectory: Bool,
        targetFile: URL,
        repoURL: URL
    ) -> String {
        // Path of the entry relative to the target file's directory.
        let targetDirRepoRelative = repoRelativePath(
            of: targetFile.deletingLastPathComponent(),
            repoURL: repoURL
        )
        let relative = stripPathPrefix(entryPath, prefix: targetDirRepoRelative)
        var path = relative
        if isDirectory && !path.hasSuffix("/") {
            path += "/"
        }
        return escapeForGitignore(path)
    }

    // MARK: - Path helpers (repo-relative, POSIX, '/' separators).

    private static func entryParentRelative(entryPath: String) -> String {
        if let slash = entryPath.lastIndex(of: "/") {
            return String(entryPath[..<slash])
        }
        return ""
    }

    private static func parentRepoRelative(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[..<slash])
        }
        return ""
    }

    private static func repoRelativePath(of url: URL, repoURL: URL) -> String {
        let repoPath = repoURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p == repoPath { return "" }
        if p.hasPrefix(repoPath + "/") {
            return String(p.dropFirst(repoPath.count + 1))
        }
        return ""
    }

    private static func stripPathPrefix(_ path: String, prefix: String) -> String {
        if prefix.isEmpty { return path }
        if path == prefix { return "" }
        if path.hasPrefix(prefix + "/") {
            return String(path.dropFirst(prefix.count + 1))
        }
        return path
    }

    private static func escapeForGitignore(_ pattern: String) -> String {
        guard !pattern.isEmpty else { return pattern }

        // Escape gitignore glob metacharacters wherever they appear in the
        // body so the pattern matches the literal path. '/' is the path
        // separator and must stay unescaped. '\\' is itself the gitignore
        // escape character, so a literal backslash in a filename is
        // doubled. Without this, paths like `src/[draft].md` or
        // `weird*name.log` get written verbatim and git interprets them
        // as patterns, leaving the actual file untracked.
        var body = ""
        body.reserveCapacity(pattern.count)
        for ch in pattern {
            switch ch {
            case "\\", "*", "?", "[":
                body.append("\\")
                body.append(ch)
            default:
                body.append(ch)
            }
        }

        // Escape leading '#' or '!' so gitignore doesn't treat them as
        // comment / negation markers. '[' is already escaped by the body
        // loop above.
        if let first = body.first, first == "#" || first == "!" {
            body = "\\" + body
        }

        // Escape a single trailing space so gitignore doesn't strip it.
        // (Multiple trailing spaces are exceptionally rare in real paths;
        // escape just the last one — that's enough to preserve all of them
        // because gitignore strips unescaped trailing whitespace only.)
        if body.hasSuffix(" ") {
            body = String(body.dropLast()) + "\\ "
        }

        return body
    }

    private static func appendPatternIfMissing(_ pattern: String, to file: URL) throws {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let existing: String
        if fm.fileExists(atPath: file.path) {
            existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        } else {
            existing = ""
        }

        // Dedup: skip if any existing line (trimmed) equals the pattern.
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces) == trimmedPattern {
                return
            }
        }

        var output = existing
        if !output.isEmpty && !output.hasSuffix("\n") {
            output += "\n"
        }
        output += pattern + "\n"

        try output.write(to: file, atomically: true, encoding: .utf8)
    }
}

private extension URL {
    /// Append a repo-relative POSIX path (e.g. "src/foo") as path components.
    func appending(pathComponentsFromRepoRelative relative: String) -> URL {
        guard !relative.isEmpty else { return self }
        var u = self
        for part in relative.split(separator: "/") {
            u = u.appendingPathComponent(String(part))
        }
        return u
    }
}
