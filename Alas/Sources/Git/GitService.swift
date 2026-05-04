import Foundation

struct GitService {
    func isGitRepository(_ path: URL) async throws -> Bool {
        let result = try await Process.git(["rev-parse", "--is-inside-work-tree"], cwd: path)
        return result.exitCode == 0 &&
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Parses `<owner>/<repo>` from `origin` remote URL, falls back to folder name.
    func suggestProjectName(_ path: URL) async throws -> String {
        let result = try await Process.git(["remote", "get-url", "origin"], cwd: path)
        guard result.exitCode == 0 else { return path.lastPathComponent }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.parseRemote(url) ?? path.lastPathComponent
    }

    static func parseRemote(_ url: String) -> String? {
        // https://host/owner/repo(.git)?  or  git@host:owner/repo(.git)?
        var trimmed = url
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        if trimmed.contains("://") {
            // https://github.com/owner/repo
            let parts = trimmed.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
        }
        if trimmed.contains("@") && trimmed.contains(":") {
            // git@github.com:owner/repo
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let pathPart = parts[1]
            let segs = pathPart.split(separator: "/")
            guard segs.count >= 2 else { return nil }
            return "\(segs[segs.count - 2])/\(segs[segs.count - 1])"
        }
        return nil
    }
}

extension GitService {
    func status(worktreePath: URL) async throws -> [ChangedFile] {
        async let statusResult = Process.git(["status", "--porcelain=v2", "-z"], cwd: worktreePath)
        async let numstatResult = Process.git(["diff", "--numstat", "HEAD"], cwd: worktreePath)
        let (s, n) = try await (statusResult, numstatResult)
        guard s.exitCode == 0 else { return [] }
        var entries = try StatusParser.parse(s.stdout)
        let counts = NumstatParser.parse(n.stdout)
        for i in entries.indices {
            if let c = counts[entries[i].path] {
                entries[i] = ChangedFile(path: entries[i].path, status: entries[i].status,
                                          add: c.add, del: c.del, renameFrom: entries[i].renameFrom)
            }
        }
        return entries
    }

    func diff(worktreePath: URL, file: String, staged: Bool = false) async throws -> ParsedDiff {
        // Untracked files have no HEAD entry, so `git diff HEAD -- <path>`
        // returns nothing. Detect via `git ls-files --error-unmatch` (exit 0
        // iff tracked) and fall back to comparing against /dev/null so the
        // user sees the file's contents as a single all-add hunk.
        let tracked = try await Process.git(
            ["ls-files", "--error-unmatch", "--", file],
            cwd: worktreePath
        )
        if tracked.exitCode != 0 && !staged {
            let result = try await Process.git(
                ["diff", "--no-color", "--no-index", "--", "/dev/null", file],
                cwd: worktreePath
            )
            // `git diff --no-index` exits non-zero (1) when there ARE differences
            // — that's the normal case for an untracked file. Only treat exit
            // codes >= 2 as real failures.
            guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
            return DiffParser.parse(result.stdout)
        }
        var args = ["diff", "--no-color"]
        if staged { args.append("--cached") }
        args.append("HEAD")
        args.append("--")
        args.append(file)
        let result = try await Process.git(args, cwd: worktreePath)
        return DiffParser.parse(result.stdout)
    }

    func fileTree(worktreePath: URL, statusEntries: [ChangedFile]) async throws -> [FileTreeNode] {
        let result = try await Process.git(
            ["ls-files", "--cached", "--others", "--exclude-standard"],
            cwd: worktreePath
        )
        let paths = result.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
        var badges: [String: String] = [:]
        for entry in statusEntries { badges[entry.path] = entry.status }
        return FileTreeBuilder.build(paths: paths, badges: badges)
    }
}
