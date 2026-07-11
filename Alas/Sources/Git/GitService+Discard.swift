import Foundation

extension GitService {
    /// Discard worktree + index changes for the given paths. Splits paths into
    /// three buckets: in-index (`indexTracked`), in-HEAD-only (`headOnlyPaths`,
    /// e.g. staged-rename origins no longer in the index), and truly untracked.
    /// In-index and HEAD-only paths route through
    /// `git restore --staged --worktree --source=HEAD --` (one batched call);
    /// untracked paths are removed from the backing filesystem. On unborn HEAD
    /// where `--source=HEAD` won't resolve, every in-index path is necessarily a
    /// staged add, so we use `git rm -f --cached --` + filesystem removal.
    /// Empty `files` is a no-op. Missing untracked paths (ENOENT) are
    /// silently tolerated — the user already saw what they wanted gone.
    func discardPaths(worktreePath: URL, files: [String]) async throws {
        guard !files.isEmpty else { return }

        let head = try await hasHead(worktreePath: worktreePath)
        let remoteHost = RemoteHostRegistry.shared.host(forPath: worktreePath.path)

        // Partition by index presence. ls-files --error-unmatch exits 0 iff
        // the path is tracked in the index (includes staged adds and renames).
        var indexTracked: [String] = []
        var notInIndex: [String] = []
        for path in files {
            let result = try await Process.git(
                ["ls-files", "--error-unmatch", "--", path],
                cwd: worktreePath
            )
            if result.exitCode == 0 {
                indexTracked.append(path)
            } else {
                notInIndex.append(path)
            }
        }

        // Among paths not in the index, some may still exist in HEAD (e.g.
        // the old name in a staged rename). Those need git restore too.
        var headOnlyPaths: [String] = []
        var trulyUntracked: [String] = []
        if head {
            for path in notInIndex {
                let result = try await Process.git(
                    ["cat-file", "-e", "HEAD:\(path)"],
                    cwd: worktreePath
                )
                if result.exitCode == 0 {
                    headOnlyPaths.append(path)
                } else {
                    trulyUntracked.append(path)
                }
            }
        } else {
            trulyUntracked = notInIndex
        }

        // Restore index-tracked paths (modifications, staged adds, renames).
        // `--recurse-submodules` is required for dirty submodule worktrees;
        // without it `git restore` leaves them at their current commit.
        if !indexTracked.isEmpty {
            if head {
                let result = try await Process.git(
                    ["restore", "--staged", "--worktree", "--recurse-submodules", "--source=HEAD", "--"]
                        + indexTracked + headOnlyPaths,
                    cwd: worktreePath
                )
                try Self.assertSuccess(result, op: "discard")
            } else {
                // Unborn HEAD: every tracked path is a staged add.
                let rm = try await Process.git(
                    ["rm", "-f", "--cached", "--"] + indexTracked,
                    cwd: worktreePath
                )
                try Self.assertSuccess(rm, op: "discard")
                for path in indexTracked {
                    try await removeUntrackedPath(worktreePath: worktreePath, path: path, remoteHost: remoteHost)
                }
            }
        } else if !headOnlyPaths.isEmpty {
            // No index-tracked paths but we have head-only paths (edge case).
            let result = try await Process.git(
                ["restore", "--staged", "--worktree", "--recurse-submodules", "--source=HEAD", "--"] + headOnlyPaths,
                cwd: worktreePath
            )
            try Self.assertSuccess(result, op: "discard")
        }

        // `git restore --recurse-submodules` resets the submodule's commit
        // and tracked content, but leaves nested untracked files behind. For
        // any path in the discard set that IS a submodule, run `git clean`
        // inside it so "Discard … (staged, unstaged, and untracked)" really
        // does leave the worktree clean.
        if head {
            for path in indexTracked + headOnlyPaths {
                guard try await isSubmodule(worktreePath: worktreePath, path: path) else {
                    continue
                }
                let submoduleURL = worktreePath.appendingPathComponent(path)
                let clean = try await Process.git(
                    ["clean", "-fd"],
                    cwd: submoduleURL
                )
                try Self.assertSuccess(clean, op: "discard")
            }
        }

        // Remove truly untracked files from disk.
        for path in trulyUntracked {
            try await removeUntrackedPath(worktreePath: worktreePath, path: path, remoteHost: remoteHost)
        }
    }

    private func removeUntrackedPath(worktreePath: URL, path: String, remoteHost: String?) async throws {
        let url = worktreePath.appendingPathComponent(path)
        guard let remoteHost else {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                return
            }
            return
        }
        let result = try await RemoteExec.run(
            host: remoteHost,
            cwd: nil,
            command: RemoteFileOps.removeCommand(path: url.path),
            timeout: 15
        )
        try Self.assertSuccess(result, op: "discard")
    }

    /// True iff `path` is a submodule registered in the index or HEAD.
    /// Submodules are mode 160000 ("gitlink") in the tree object. We probe
    /// the index first (the common case after a restore) and fall back to
    /// HEAD for rename origins that aren't in the current index.
    private func isSubmodule(worktreePath: URL, path: String) async throws -> Bool {
        if let stage = try? await Process.git(
            ["ls-files", "--stage", "--", path],
            cwd: worktreePath
        ), stage.exitCode == 0, stage.stdout.hasPrefix("160000") {
            return true
        }
        if let tree = try? await Process.git(
            ["ls-tree", "HEAD", "--", path],
            cwd: worktreePath
        ), tree.exitCode == 0, tree.stdout.hasPrefix("160000") {
            return true
        }
        return false
    }

    /// Apply a unified-diff patch in reverse against the worktree. Used by
    /// per-hunk "Discard hunk" for tracked files. Pipes the patch over stdin
    /// so the same path works for local and SSH-backed worktrees. Throws if
    /// `git apply --reverse` exits non-zero —
    /// typically because the patch context no longer matches the working
    /// copy (e.g. the user already discarded it elsewhere).
    func applyPatchReverse(worktreePath: URL, patch: String) async throws {
        let result = try await Process.git(
            ["apply", "--reverse", "-"],
            cwd: worktreePath,
            stdin: patch
        )
        try Self.assertSuccess(result, op: "applyPatchReverse")
    }
}
