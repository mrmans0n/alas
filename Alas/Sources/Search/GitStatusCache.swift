import Foundation
import os

/// Per-worktree cache of `git status --porcelain` output, parsed down to
/// the M/A/D/R badge set used by the search dialog. Cache TTL is 2s — the
/// dialog only ever asks for these on first open and on result re-renders,
/// and 2s is fresh enough to feel right after a save.
///
/// Status precedence (when both index and worktree show changes for the
/// same file): we use the index status if non-blank, otherwise the
/// worktree status. This matches the user-perceived "what changed?".
actor GitStatusCache {
    private let logger = Logger(subsystem: "io.nlopez.alas", category: "search.status")
    private var cache: [String: (timestamp: Date, statuses: [String: GitStatusBadge])] = [:]
    private let ttl: TimeInterval = 2

    func statuses(for worktree: SearchWorktree) async throws -> [String: GitStatusBadge] {
        try await statuses(forWorktreePath: worktree.absolutePath, remoteHost: worktree.remoteHost, cacheKey: worktree.cacheKey)
    }

    func statuses(forWorktreePath worktree: URL) async throws -> [String: GitStatusBadge] {
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktree.path)
        let key = remoteHost.map { "ssh:\($0):\(worktree.path)" } ?? "local:\(worktree.path)"
        return try await statuses(forWorktreePath: worktree, remoteHost: remoteHost, cacheKey: key)
    }

    private func statuses(forWorktreePath worktree: URL, remoteHost: String?, cacheKey key: String) async throws -> [String: GitStatusBadge] {
        if let hit = cache[key], Date().timeIntervalSince(hit.timestamp) < ttl {
            return hit.statuses
        }

        let result = try await Process.git(
            ["-c", "core.quotePath=false", "status", "--porcelain=v1", "--no-renames", "-z"],
            cwd: worktree,
            remoteHost: remoteHost
        )
        guard result.exitCode == 0 else {
            logger.error("git status exit \(result.exitCode): \(result.stderr)")
            throw NSError(
                domain: "GitStatusCache",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: result.stderr]
            )
        }

        var map: [String: GitStatusBadge] = [:]
        for entry in result.stdout.split(separator: "\0", omittingEmptySubsequences: true) {
            // With -z, format is "XY path" NUL-delimited (X = index status, Y = worktree status).
            let raw = String(entry)
            guard raw.count >= 4 else { continue }
            let chars = Array(raw)
            let indexCh = chars[0]
            let worktreeCh = chars[1]
            // Path begins at index 3 (chars 0..1 = XY, char 2 = space).
            let path = String(chars[3...])
            let badge = badge(forIndex: indexCh, worktree: worktreeCh)
            if let badge { map[path] = badge }
        }

        cache[key] = (Date(), map)
        return map
    }

    func invalidate(forWorktreePath worktree: URL) {
        cache.removeValue(forKey: worktree.path)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    /// Map porcelain XY codes to a single badge. Untracked (`??`) → nil
    /// (the design's empty-state sort uses badges only; untracked files
    /// don't get one).
    private func badge(forIndex i: Character, worktree w: Character) -> GitStatusBadge? {
        // Renames passed `--no-renames` will appear as D+A pairs instead;
        // we still keep R in the enum for completeness in case we change
        // the flag later.
        switch (i, w) {
        case ("?", "?"): return nil
        case ("!", "!"): return nil
        case ("M", _),  (_, "M"): return .modified
        case ("A", _),  (_, "A"): return .added
        case ("D", _),  (_, "D"): return .deleted
        case ("R", _),  (_, "R"): return .renamed
        default: return nil
        }
    }
}
