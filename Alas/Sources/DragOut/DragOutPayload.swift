import Foundation

/// What a draggable row hands to the drag machinery. Every reason a drag can be
/// impossible — a remote worktree, a deleted file, a blob missing at that
/// revision — collapses into `resolve()` returning nil, so call sites carry no
/// error handling of their own.
enum DragOutPayload: Equatable, Sendable {
    /// A file or directory that exists in a local worktree. Dragging this hands
    /// over the live file, so edits in the receiving app land back in the repo.
    case onDisk(URL)

    /// A blob at a git revision, materialized to a temp file on demand.
    case revision(worktreePath: URL, ref: String, path: String)

    func resolve(using cache: RevisionSnapshotCache = .shared) async -> URL? {
        switch self {
        case .onDisk(let url):
            guard !url.isRemoteAlasPath else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        case .revision(let worktreePath, let ref, let path):
            guard !worktreePath.isRemoteAlasPath else { return nil }
            return await cache.snapshot(worktreePath: worktreePath, ref: ref, path: path)
        }
    }
}

extension DragOutPayload {
    static func workingTreeFile(worktreePath: URL, relativePath: String) -> DragOutPayload {
        .onDisk(worktreePath.appendingPathComponent(relativePath))
    }

    /// Untracked files live on the stash commit's third parent; tracked files
    /// live on the stash commit itself.
    static func stashFile(worktreePath: URL, stash: GitStash, file: GitStashFile) -> DragOutPayload {
        .revision(
            worktreePath: worktreePath,
            // The stash's SHA, not its `stash@{N}` reflog name: that name is
            // positional, so a stash pushed between rendering the row and
            // starting the drag would silently resolve to a different stash.
            ref: file.isUntracked ? "\(stash.sha)^3" : stash.sha,
            path: file.path
        )
    }

    static func commitFile(worktreePath: URL, sha: String, file: CommitChangedFile) -> DragOutPayload {
        .revision(worktreePath: worktreePath, ref: sha, path: file.path)
    }
}
