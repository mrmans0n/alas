import Foundation

/// What a draggable row hands to the drag machinery. Every reason a drag can be
/// impossible — a remote worktree, a deleted file, a blob missing at that
/// revision — collapses into `resolve()` returning nil, so call sites carry no
/// error handling of their own.
enum DragOutPayload: Equatable, Sendable {
    /// A file or directory that exists in a local worktree. Dragging this hands
    /// over the live file, so edits in the receiving app land back in the repo.
    case onDisk(URL, insertion: AlasDropPayload? = nil)

    /// A blob at a git revision, materialized to a temp file on demand.
    case revision(worktreePath: URL, ref: String, path: String)

    /// Text with no corresponding file representation, such as a commit SHA.
    case commitSHA(String)

    func resolve(using cache: RevisionSnapshotCache = .shared) async -> URL? {
        switch self {
        case .onDisk(let url, _):
            guard !url.isRemoteAlasPath else { return nil }
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        case .revision(let worktreePath, let ref, let path):
            guard !worktreePath.isRemoteAlasPath else { return nil }
            return await cache.snapshot(worktreePath: worktreePath, ref: ref, path: path)
        case .commitSHA:
            return nil
        }
    }

    func prepare(using cache: RevisionSnapshotCache = .shared) async -> DragOutPreparedItem? {
        switch self {
        case .onDisk(let url, let insertion):
            guard !url.isRemoteAlasPath,
                  FileManager.default.fileExists(atPath: url.path)
            else {
                return insertion.map {
                    DragOutPreparedItem(dropPayload: $0, fileURL: nil, publicText: nil)
                }
            }
            return DragOutPreparedItem(
                dropPayload: insertion,
                fileURL: url,
                publicText: url.path
            )
        case .revision:
            guard let url = await resolve(using: cache) else { return nil }
            return DragOutPreparedItem(dropPayload: nil, fileURL: url, publicText: url.path)
        case .commitSHA(let sha):
            return DragOutPreparedItem(
                dropPayload: .commitSHA(sha),
                fileURL: nil,
                publicText: sha
            )
        }
    }
}

extension DragOutPayload {
    static func workingTreeFile(worktreePath: URL, relativePath: String) -> DragOutPayload {
        let absoluteURL = worktreePath.appendingPathComponent(relativePath)
        return .onDisk(
            absoluteURL,
            insertion: .file(relativePath: relativePath, absolutePath: absoluteURL.path)
        )
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
