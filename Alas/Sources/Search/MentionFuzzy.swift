import Foundation

enum MentionFuzzy {
    static func deduplicated(files: [URL], relativeTo root: URL) -> [URL] {
        var result: [URL] = []
        var indices: [String: Int] = [:]
        for file in files {
            let path = relativePath(for: file, root: root)
            if let index = indices[path] {
                if file.hasDirectoryPath { result[index] = file }
            } else {
                indices[path] = result.count
                result.append(file)
            }
        }
        return result
    }

    /// Generated or tooling directories a non-git walk never descends into.
    static let skippedDirectoryNames: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData", ".alas",
        ".next", "dist", "out", "target", ".venv", "venv", ".tox", ".cache",
        "__pycache__", ".idea", ".vscode", ".superpowers",
    ]

    /// `includesDirectories: false` yields only files, so `limit` counts files alone.
    static func collectFiles(under root: URL, limit: Int, includesDirectories: Bool = true) -> [URL] {
        var out: [URL] = []
        let skipDirs = skippedDirectoryNames
        guard let it = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: []
        ) else { return [] }

        for case let url as URL in it {
            if out.count >= limit { break }
            let name = url.lastPathComponent
            if skipDirs.contains(name), url.hasDirectoryPath {
                it.skipDescendants()
                continue
            }
            if name.hasPrefix(".") {
                it.skipDescendants()
                continue
            }
            if !includesDirectories, url.hasDirectoryPath { continue }
            // Directories are pickable too — the enumerator yields them with
            // `hasDirectoryPath` set, which the picker uses to show a folder
            // icon and to emit a directory resource link. We still recurse into
            // them (no `skipDescendants`) so their files remain available.
            out.append(url)
        }
        out.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        return out
    }

    /// Derive every directory implied by a set of worktree-relative paths, as
    /// directory-flagged URLs under `root`. `git ls-files` only emits files
    /// (collapsing untracked directories to a trailing-slash entry), so tracked
    /// directories never appear on their own — we reconstruct the full set from
    /// each path's ancestors. A trailing slash marks the whole path as a
    /// directory; otherwise the last component is a file and is dropped.
    static func ancestorDirectories(forRelativePaths paths: [String], root: URL) -> [URL] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let isDirEntry = path.hasSuffix("/")
            let comps = path.split(separator: "/").map(String.init)
            let dirCount = isDirEntry ? comps.count : comps.count - 1
            guard dirCount > 0 else { continue }
            for end in 1...dirCount {
                let dir = comps[0..<end].joined(separator: "/")
                if seen.insert(dir).inserted { ordered.append(dir) }
            }
        }
        return ordered.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Directory URLs to add to the picker for a `git ls-files`-style listing.
    /// The caller resolves each entry's on-disk directory-ness: untracked
    /// directories arrive collapsed with git's trailing slash, but submodule
    /// gitlinks arrive like a file path (no slash). Normalizing directory
    /// entries to a trailing slash lets `ancestorDirectories` emit the entry
    /// itself — not just its parent — so submodule folders stay pickable.
    static func pickerDirectories(forEntries entries: [(path: String, isDirectory: Bool)], root: URL) -> [URL] {
        let normalized = entries.map { entry -> String in
            entry.isDirectory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
        }
        return ancestorDirectories(forRelativePaths: normalized, root: root)
    }

    static func rank(files: [URL], query: String, limit: Int, relativeTo root: URL) -> [URL] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return Array(files.prefix(limit)) }

        let normalizedQuery = query.lowercased()
        var scored: [(url: URL, pathPriority: Int, score: Double, relativePath: String)] = []
        for f in files {
            let relativePath = relativePath(for: f, root: root)
            guard let score = score(file: f, relativePath: relativePath, tokens: tokens) else {
                continue
            }
            let normalizedPath = relativePath.lowercased()
            let pathPriority = normalizedPath == normalizedQuery ? 3
                : normalizedPath.hasPrefix(normalizedQuery) ? 2
                : normalizedPath.contains(normalizedQuery) ? 1
                : 0
            scored.append((f, pathPriority, score, relativePath))
        }
        scored.sort {
            if $0.pathPriority != $1.pathPriority { return $0.pathPriority > $1.pathPriority }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count < $1.relativePath.count
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.url))
    }

    private static func score(file: URL, relativePath: String, tokens: [String]) -> Double? {
        var total = 0.0
        for token in tokens {
            let nameScore = FuzzyMatch.score(query: token, target: file.lastPathComponent)?
                .score
                .advanced(by: 8)
            let pathScore = FuzzyMatch.score(query: token, target: relativePath)?.score
            guard let best = [nameScore, pathScore].compactMap(\.self).max() else {
                return nil
            }
            total += best
        }
        return total - Double(relativePath.count) * 0.001
    }

    private static func relativePath(for file: URL, root: URL) -> String {
        let commonRoot = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = commonRoot.hasSuffix("/") ? commonRoot : commonRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
