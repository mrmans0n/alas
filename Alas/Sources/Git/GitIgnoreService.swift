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
    static func appendIgnore(
        entryPath: String,
        isDirectory: Bool,
        destination: IgnoreDestination,
        repoURL: URL
    ) throws -> URL {
        let target = try resolveTarget(
            destination: destination,
            repoURL: repoURL,
            entryPath: entryPath
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
        entryPath: String
    ) throws -> URL {
        switch destination {
        case .repoRoot:
            return repoURL.appendingPathComponent(".gitignore")
        case .infoExclude:
            return repoURL
                .appendingPathComponent(".git")
                .appendingPathComponent("info")
                .appendingPathComponent("exclude")
        case .nearest:
            // Implemented in a later task.
            return repoURL.appendingPathComponent(".gitignore")
        }
    }

    private static func computePattern(
        entryPath: String,
        isDirectory: Bool,
        targetFile: URL,
        repoURL: URL
    ) -> String {
        // The pattern path is relative to the target file's directory.
        // For repoRoot and infoExclude that's the repo root, so the entry
        // path is already relative.
        var path = entryPath
        if isDirectory && !path.hasSuffix("/") {
            path += "/"
        }
        return escapeForGitignore(path)
    }

    private static func escapeForGitignore(_ pattern: String) -> String {
        // Will be implemented when escaping tests land. For now, identity.
        return pattern
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
