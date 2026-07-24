import Foundation

/// Pure logic mapping a `ChangedFile` (working-copy) or a
/// `CommitChangedFile` (commit) → which kind of image diff this is, plus
/// the old path when renamed. Kept separate from the blob-fetching code so
/// it can be unit-tested without touching git.
enum ImageDiffPairResolver {
    struct Result: Equatable {
        let kind: ImageDiffPairKind
        let oldPath: String?
    }

    /// Working-copy resolution.
    ///
    /// - parameter entry: The `ChangedFile` from `GitService.status(...)`
    ///   for this path (or nil if the file is on disk but git has no entry
    ///   for it — treated as added).
    /// - parameter fileExistsOnDisk: Whether the working-tree file is
    ///   present. Used to disambiguate "D" entries (deleted) from edge
    ///   cases where status thinks the file exists but it doesn't.
    /// - parameter staged: Whether this is being resolved for the staged
    ///   side (HEAD vs index). When true, working-tree state is irrelevant.
    static func resolveWorkingCopy(
        entry: ChangedFile?,
        fileExistsOnDisk: Bool,
        staged: Bool
    ) -> Result {
        guard let entry else {
            // No status entry. If the file is on disk, treat as added —
            // this covers untracked files that the caller still wants to
            // show in the diff view. If neither git nor disk knows about
            // it, the only sensible reading is deleted.
            return Result(
                kind: fileExistsOnDisk ? .added : .deleted,
                oldPath: nil
            )
        }
        switch entry.status {
        case "A":
            return Result(kind: .added, oldPath: nil)
        case "D":
            return Result(kind: .deleted, oldPath: nil)
        case "R":
            // A "R" entry without `renameFrom` would leave the loader with
            // no path to fetch the "before" blob from. Treat it as plain
            // modified — we still have a valid current path.
            if let renameFrom = entry.renameFrom {
                return Result(kind: .renamed, oldPath: renameFrom)
            }
            return Result(kind: .modified, oldPath: nil)
        default:
            // "M", "T", "?" all become "modified" — we already have
            // both blobs to compare.
            //
            // The fileExistsOnDisk fallback to .deleted only applies for
            // the unstaged side, where missing-from-disk genuinely means
            // "deleted in working tree". The staged side is HEAD-vs-index
            // and ignores the working tree, so an "MD" file (staged-M +
            // unstaged-D) must stay .modified when read as staged.
            if staged {
                return Result(kind: .modified, oldPath: nil)
            }
            return fileExistsOnDisk
                ? Result(kind: .modified, oldPath: nil)
                : Result(kind: .deleted, oldPath: nil)
        }
    }

    /// Commit-side resolution. `CommitChangedFile` already carries the
    /// `originalPath` for renames, so this is a thin status-letter dispatch.
    static func resolveCommit(entry: CommitChangedFile) -> Result {
        switch entry.status {
        case "A":
            return Result(kind: .added, oldPath: nil)
        case "D":
            return Result(kind: .deleted, oldPath: nil)
        case "R":
            return Result(kind: .renamed, oldPath: entry.originalPath)
        case "C":
            return Result(kind: .copied, oldPath: entry.originalPath)
        default:
            return Result(kind: .modified, oldPath: nil)
        }
    }
}
