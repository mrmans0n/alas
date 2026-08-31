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
        try await entries(forWorktreePath: worktree.absolutePath, remoteHost: worktree.remoteHost, cacheKey: worktree.cacheKey)
    }

    func entries(forWorktreePath worktree: URL) async throws -> [Entry] {
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktree.path)
        let key = remoteHost.map { "ssh:\($0):\(worktree.path)" } ?? "local:\(worktree.path)"
        return try await entries(forWorktreePath: worktree, remoteHost: remoteHost, cacheKey: key)
    }

    private func entries(forWorktreePath worktree: URL, remoteHost: String?, cacheKey key: String) async throws -> [Entry] {
        if let hit = cache[key], Date().timeIntervalSince(hit.timestamp) < ttl {
            return hit.entries
        }

        let result: ProcessResult
        do {
            result = try await Process.git(
                ["-c", "core.quotePath=false", "ls-files", "-coz", "--exclude-standard"],
                cwd: worktree,
                remoteHost: remoteHost
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

        let entries = result.stdout
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map { line -> Entry in
                let path = String(line)
                let ext = (path as NSString).pathExtension.lowercased()
                return Entry(relativePath: path, ext: ext)
            }
        cache[key] = (Date(), entries)
        return entries
    }

    func invalidate(forWorktreePath worktree: URL) {
        cache.removeValue(forKey: worktree.path)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
