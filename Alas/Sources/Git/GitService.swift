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
    /// Whether the repo has any commits yet. `git diff HEAD` and friends
    /// fail with `bad revision 'HEAD'` on unborn branches; callers swap to
    /// index-based diffs in that case.
    func hasHead(worktreePath: URL) async throws -> Bool {
        let result = try await Process.git(
            ["rev-parse", "--verify", "--quiet", "HEAD"],
            cwd: worktreePath
        )
        return result.exitCode == 0
    }

    func status(worktreePath: URL) async throws -> [ChangedFile] {
        async let statusResult = Process.git(["status", "--porcelain=v2", "-z"], cwd: worktreePath)
        let s = try await statusResult
        guard s.exitCode == 0 else { return [] }
        var entries = try StatusParser.parse(s.stdout)

        // Numstat needs a base revision. Use HEAD if one exists; on unborn
        // branches diff `--cached` (index vs empty tree) so initial-commit
        // workflows still see real add/del counts in the Changes pane.
        let head = try await hasHead(worktreePath: worktreePath)
        let numstatArgs: [String] = head
            ? ["diff", "--numstat", "HEAD"]
            : ["diff", "--numstat", "--cached"]
        let numstat = try await Process.git(numstatArgs, cwd: worktreePath)
        let counts = NumstatParser.parse(numstat.stdout)

        for i in entries.indices {
            if let c = counts[entries[i].path] {
                entries[i] = ChangedFile(path: entries[i].path,
                                          status: entries[i].status,
                                          stage: entries[i].stage,
                                          add: c.add,
                                          del: c.del,
                                          renameFrom: entries[i].renameFrom)
            } else if entries[i].add == 0 && entries[i].del == 0 {
                // Numstat doesn't include unstaged untracked files, so they'd
                // show 0/0 in the Changes pane and the totals would
                // under-report. Count the file's lines as adds when it exists
                // on disk; deleted files (no longer present) stay at 0/0.
                let url = worktreePath.appendingPathComponent(entries[i].path)
                if let data = try? Data(contentsOf: url),
                   let text = String(data: data, encoding: .utf8) {
                    let lines = text.isEmpty
                        ? 0
                        : text.split(separator: "\n", omittingEmptySubsequences: false).count
                    entries[i] = ChangedFile(path: entries[i].path,
                                             status: entries[i].status,
                                             stage: entries[i].stage,
                                             add: lines,
                                             del: 0,
                                             renameFrom: entries[i].renameFrom)
                }
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

        // Two distinct views, never combine HEAD and worktree:
        //   staged: false → unstaged delta (worktree vs index): `git diff`.
        //     Works as-is on unborn HEAD (index may be empty tree). This is
        //     the patch shape `git apply --cached` expects when staging
        //     hunks, and it correctly surfaces AM-state worktree edits even
        //     on unborn branches.
        //   staged: true  → staged delta (index vs HEAD): `git diff --cached
        //     HEAD` when HEAD exists, otherwise `git diff --cached` (index
        //     vs empty tree) so initial-commit workflows still render the
        //     staged side.
        let head = try await hasHead(worktreePath: worktreePath)
        var args = ["diff", "--no-color"]
        if staged {
            args.append("--cached")
            if head { args.append("HEAD") }
        }
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
