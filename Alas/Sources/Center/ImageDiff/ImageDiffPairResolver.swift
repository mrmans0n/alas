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
    static func resolveWorkingCopy(
        entry: ChangedFile?,
        fileExistsOnDisk: Bool
    ) -> Result {
        guard let entry else {
            // No status entry. If the file is on disk, treat as added —
            // this covers untracked files that the caller still wants to
            // show in the diff view.
            return Result(kind: .added, oldPath: nil)
        }
        switch entry.status {
        case "A":
            return Result(kind: .added, oldPath: nil)
        case "D":
            return Result(kind: .deleted, oldPath: nil)
        case "R":
            return Result(kind: .renamed, oldPath: entry.renameFrom)
        default:
            // "M", "T", "?" all become "modified" — we already have
            // both blobs to compare.
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
        case "R", "C":
            return Result(kind: .renamed, oldPath: entry.originalPath)
        default:
            return Result(kind: .modified, oldPath: nil)
        }
    }
}
