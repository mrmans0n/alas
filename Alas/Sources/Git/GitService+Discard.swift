import Foundation

extension GitService {
    /// Discard worktree + index changes for the given paths. Splits paths
    /// into tracked vs untracked: tracked paths go through
    /// `git restore --staged --worktree --source=HEAD --` (one batched call);
    /// untracked paths are removed via `FileManager`. On unborn HEAD where
    /// `--source=HEAD` won't resolve, every tracked path is necessarily a
    /// staged add, so we use `git rm -f --cached --` + `FileManager` removal.
    /// Empty `files` is a no-op. Missing untracked paths (ENOENT) are
    /// silently tolerated — the user already saw what they wanted gone.
    ///
    /// Staged renames are handled correctly: after `git mv a.txt b.txt` the
    /// old path `a.txt` is no longer in the index but still exists in HEAD.
    /// We detect such paths via `git cat-file -e HEAD:<path>` and include
    /// them in the restore call so both halves of the rename are undone.
    func discardPaths(worktreePath: URL, files: [String]) async throws {
        guard !files.isEmpty else { return }

        let head = try await hasHead(worktreePath: worktreePath)

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
        if !indexTracked.isEmpty {
            if head {
                let result = try await Process.git(
                    ["restore", "--staged", "--worktree", "--source=HEAD", "--"]
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
                    let url = worktreePath.appendingPathComponent(path)
                    try? FileManager.default.removeItem(at: url)
                }
            }
        } else if !headOnlyPaths.isEmpty {
            // No index-tracked paths but we have head-only paths (edge case).
            let result = try await Process.git(
                ["restore", "--staged", "--worktree", "--source=HEAD", "--"] + headOnlyPaths,
                cwd: worktreePath
            )
            try Self.assertSuccess(result, op: "discard")
        }

        // Remove truly untracked files from disk.
        for path in trulyUntracked {
            let url = worktreePath.appendingPathComponent(path)
            do {
                try FileManager.default.removeItem(at: url)
            } catch let error as NSError where error.code == NSFileNoSuchFileError {
                continue
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }
}
