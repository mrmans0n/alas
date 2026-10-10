import Foundation
import os

/// Enumerates files in a worktree using
/// `git ls-files -co --exclude-standard`. Cached per worktree path
/// for the lifetime of one dialog session.
///
/// `Entry` is intentionally minimal — it has no `worktreeId`/`projectId`
/// because those come from the caller (SearchModel knows which worktree
/// it asked for). The model wraps these into `FileSearchResult`s.
actor FileIndex {
    struct Entry: Equatable, Sendable {
        let relativePath: String
        let ext: String
    }

    private let logger = Logger(subsystem: "io.nlopez.alas", category: "search.fileindex")

    /// In-memory cache keyed by location-qualified absolute worktree path. Cleared by
    /// `invalidate(forWorktreePath:)` and `invalidateAll()`.
    private var cache: [String: (timestamp: Date, entries: [Entry])] = [:]

    /// Cache TTL — first dialog open builds the index, subsequent opens
    /// in the next 30s reuse it.
    private let ttl: TimeInterval = 30

    func entries(for worktree: SearchWorktree) async throws -> [Entry] {
        try await entries(
            forWorktreePath: worktree.absolutePath,
            remoteHost: worktree.remoteHost,
            usesRemoteHostRegistry: worktree.usesRemoteHostRegistry,
            cacheKey: worktree.cacheKey,
            isFolder: worktree.isFolder
        )
    }

    /// `isFolder` lists a folder project's files from the filesystem, since it
    /// has no git to ask.
    func entries(forWorktreePath worktree: URL, isFolder: Bool = false) async throws -> [Entry] {
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktree.path)
        let key = remoteHost.map { "ssh:\($0):\(worktree.path)" } ?? "local:\(worktree.path)"
        return try await entries(
            forWorktreePath: worktree, remoteHost: remoteHost, usesRemoteHostRegistry: true,
            cacheKey: key, isFolder: isFolder
        )
    }

    private func entries(
        forWorktreePath worktree: URL,
        remoteHost: String?,
        usesRemoteHostRegistry: Bool,
        cacheKey baseKey: String,
        isFolder: Bool
    ) async throws -> [Entry] {
        // Git and folder listings of one path differ, so they never share an entry.
        let key = isFolder ? "folder:" + baseKey : baseKey
        if let hit = cache[key], Date().timeIntervalSince(hit.timestamp) < ttl {
            return hit.entries
        }
        let paths = isFolder
            ? try await folderFilePaths(worktree, remoteHost: remoteHost)
            : try await gitFilePaths(worktree, remoteHost: remoteHost, usesRemoteHostRegistry: usesRemoteHostRegistry)
        let entries = paths.map { path in
            Entry(relativePath: path, ext: (path as NSString).pathExtension.lowercased())
        }
        cache[key] = (Date(), entries)
        return entries
    }

    // ponytail: same skip list and cap as the @-mention walk; no .gitignore
    // semantics, since a folder has no git to define them.
    static let folderFileLimit = 50_000

    private func folderFilePaths(_ worktree: URL, remoteHost: String?) async throws -> [String] {
        if let remoteHost {
            let result = try await RemoteExec.run(
                host: remoteHost,
                cwd: worktree.path,
                // Newline-delimited because BSD head has no -z; a filename
                // containing a newline is split, which only mislists that file.
                command: "find . -name '.*' ! -name . -prune -o -type f -print | head -n \(Self.folderFileLimit)"
            )
            guard result.exitCode == 0 else {
                throw NSError(
                    domain: "FileIndex",
                    code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: "find failed: \(result.stderr)"]
                )
            }
            return result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
        }
        let root = worktree.standardizedFileURL.path + "/"
        return MentionFuzzy.collectFiles(under: worktree, limit: Self.folderFileLimit)
            .filter { !$0.hasDirectoryPath }
            .compactMap { url in
                let path = url.standardizedFileURL.path
                return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
            }
    }

    private func gitFilePaths(_ worktree: URL, remoteHost: String?, usesRemoteHostRegistry: Bool) async throws -> [String] {
        let result: ProcessResult
        do {
            result = try await Process.git(
                ["-c", "core.quotePath=false", "ls-files", "-coz", "--exclude-standard"],
                cwd: worktree,
                remoteHost: remoteHost,
                usesRemoteHostRegistry: usesRemoteHostRegistry
            )
        } catch {
            logger.error("git ls-files failed in \(worktree.path): \(error.localizedDescription)")
            throw error
        }
        guard result.exitCode == 0 else {
            logger.error("git ls-files exit \(result.exitCode) in \(worktree.path): \(result.stderr)")
            throw NSError(
                domain: "FileIndex",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "git ls-files failed: \(result.stderr)"]
            )
        }

        return result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func invalidate(forWorktreePath worktree: URL) {
        let path = worktree.path
        cache = cache.filter { key, _ in
            key != path
                && key != "local:\(path)"
                && !key.hasSuffix(":\(path)")
        }
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
