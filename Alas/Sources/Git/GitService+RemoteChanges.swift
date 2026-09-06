import Foundation

/// Base-relative views used by the remote changes surface. Unlike the desktop
/// Changes panel (working tree vs index/HEAD), these compare the whole
/// worktree — commits plus uncommitted work — against the comparison ref, so
/// the remote client shows everything an agent did on this branch.
extension GitService {
    /// Changed files between `ref` and the working tree, plus untracked files.
    /// A nil `ref` (unborn branch, no resolvable base) falls back to `status`.
    func changedFilesAgainstRef(worktreePath: URL, ref: String?) async throws -> [ChangedFile] {
        guard let ref, !ref.isEmpty else {
            return try await status(worktreePath: worktreePath)
        }

        let numstat = try await Process.git(
            ["diff", "--numstat", "-M", "-C", ref, "--"], cwd: worktreePath)
        guard numstat.exitCode == 0 else {
            return try await status(worktreePath: worktreePath)
        }
        let counts = NumstatParser.parse(numstat.stdout)

        let nameStatus = try await Process.git(
            ["diff", "--name-status", "-M", "-C", ref, "--"], cwd: worktreePath)
        let statusEntries = try await status(worktreePath: worktreePath)
        let conflicts = Dictionary(
            statusEntries.compactMap { entry in entry.conflict.map { (entry.path, $0) } },
            uniquingKeysWith: { first, _ in first })

        var files: [ChangedFile] = []
        var seen = Set<String>()
        for line in nameStatus.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard let code = parts.first, parts.count >= 2 else { continue }
            let letter = String(code.prefix(1))
            // Rename/copy entries carry both the source and destination path.
            let path = parts.count >= 3 ? parts[2] : parts[1]
            let renameFrom = parts.count >= 3 ? parts[1] : nil
            guard seen.insert(path).inserted else { continue }
            let count = counts[path] ?? (add: 0, del: 0)
            files.append(ChangedFile(
                path: path,
                status: letter,
                stage: .unstaged,   // not meaningful for a base-relative view
                add: count.add,
                del: count.del,
                renameFrom: renameFrom,
                conflict: conflicts[path]))
        }

        let untracked = try await Process.git(
            ["ls-files", "--others", "--exclude-standard"], cwd: worktreePath)
        let untrackedPaths = untracked.stdout.split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        // `addedLineCount` shells out to `Data(contentsOf:)` against a LOCAL
        // URL, which silently reads nothing (0 lines) for a remote worktree
        // path — batch a single remote round-trip instead, mirroring
        // `status(worktreePath:)`'s identical remote/local split for
        // untracked line counts.
        let remoteCounts: [String: Int]
        if worktreePath.isRemoteAlasPath, let host = RemoteHostRegistry.shared.host(forPath: worktreePath.path) {
            remoteCounts = await RemoteFileStats.lineCounts(host: host, cwd: worktreePath.path, paths: untrackedPaths)
        } else {
            remoteCounts = [:]
        }

        for path in untrackedPaths {
            let add = worktreePath.isRemoteAlasPath
                ? (remoteCounts[path] ?? 0)
                : Self.addedLineCount(worktreePath: worktreePath, path: path)
            files.append(ChangedFile(
                path: path,
                status: "A",
                stage: .unstaged,
                add: add,
                del: 0,
                renameFrom: nil,
                conflict: nil))
        }

        return files.sorted { $0.path < $1.path }
    }

    /// Diff of one file between `ref` and the working tree. Untracked files
    /// diff against /dev/null so they render as a single all-add hunk. A nil
    /// `ref` falls back to the working-tree diff.
    ///
    /// A file renamed since `ref` did not exist at `ref` under its CURRENT
    /// path (it existed under its OLD path), so the plain `cat-file -e`
    /// existence check below would otherwise treat it as untracked/new and
    /// diff the whole current content against `/dev/null` instead of
    /// showing the rename's actual edits. `renameSource` catches that case
    /// first by consulting the unrestricted (no-pathspec) rename-aware
    /// name-status diff — pathspec-restricting `git diff -M -C ref --
    /// <file>` does NOT detect the rename, because git's pathspec filtering
    /// happens before rename pairing, so it never sees the old path to pair
    /// against.
    func diff(worktreePath: URL, againstRef ref: String?, file: String) async throws -> ParsedDiff {
        guard let ref, !ref.isEmpty else {
            return try await diff(worktreePath: worktreePath, file: file)
        }

        if let originalPath = try await renameSource(worktreePath: worktreePath, ref: ref, file: file) {
            let result = try await Process.git(
                ["diff", "--no-color", "-M", "-C", ref, "--", file, originalPath], cwd: worktreePath)
            guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
            return DiffParser.parse(Self.sliceDiffForFile(result.stdout, file: file))
        }

        // Check if file exists at ref (not just in current index) to handle deleted files correctly.
        let existsAtRef = try await Process.git(
            ["cat-file", "-e", "\(ref):\(file)"], cwd: worktreePath)
        if existsAtRef.exitCode != 0 {
            // File doesn't exist at ref (untracked/new file), so diff against /dev/null.
            let result = try await Process.git(
                ["diff", "--no-color", "--no-index", "--", "/dev/null", file], cwd: worktreePath)
            // `--no-index` exits 1 when there ARE differences, which is the
            // normal case here; only >= 2 is a real failure.
            guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
            return DiffParser.parse(result.stdout)
        }

        // File exists at ref (tracked or previously committed), so diff ref to current state.
        let result = try await Process.git(
            ["diff", "--no-color", "-M", "-C", ref, "--", file], cwd: worktreePath)
        guard result.exitCode <= 1 else { return ParsedDiff(hunks: []) }
        return DiffParser.parse(result.stdout)
    }

    /// Looks up the source path of a rename that landed `file` at its
    /// current path since `ref`, or nil when `file` was not renamed (it's
    /// untracked, unchanged, or was modified/deleted/added without a
    /// rename). Scans the UNRESTRICTED rename-aware name-status diff (no
    /// pathspec) rather than one scoped to `file`, since pathspec
    /// restriction happens before rename pairing in git and would hide the
    /// old path entirely.
    private func renameSource(worktreePath: URL, ref: String, file: String) async throws -> String? {
        let result = try await Process.git(
            ["diff", "--name-status", "-M", "-C", ref], cwd: worktreePath)
        guard result.exitCode == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 3, let status = parts.first, status.hasPrefix("R"), parts[2] == file else { continue }
            return parts[1]
        }
        return nil
    }

    /// Sniffs whether the blob at `ref:file` looks binary, for files that no
    /// longer exist in the working tree (so an on-disk sniff can't tell).
    /// Returns nil when `file` doesn't exist at `ref` either — nothing to
    /// sniff, so the caller should fall back to its prior on-disk verdict.
    func looksBinaryAtRef(worktreePath: URL, ref: String, file: String) async throws -> Bool? {
        let existsAtRef = try await Process.git(
            ["cat-file", "-e", "\(ref):\(file)"], cwd: worktreePath)
        guard existsAtRef.exitCode == 0 else { return nil }
        let blob = try await Process.gitData(["show", "\(ref):\(file)"], cwd: worktreePath)
        guard blob.exitCode == 0 else { return nil }
        return Self.looksBinary(blob.stdout)
    }

    /// Line count for an untracked file, or 0 when it is binary or unreadable.
    private static func addedLineCount(worktreePath: URL, path: String) -> Int {
        let url = worktreePath.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url), !looksBinary(data),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        if text.isEmpty { return 0 }
        return text.hasSuffix("\n")
            ? text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
            : text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
