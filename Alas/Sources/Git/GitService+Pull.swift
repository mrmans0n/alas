import Foundation

extension GitService {
    /// Pulls the current branch's upstream by fetching it fresh and rebasing
    /// onto the updated remote-tracking ref. Fast-forwards when there are no
    /// local commits to replay; otherwise replays them. Conflicts surface as a
    /// `.conflict` result (the worktree is left mid-rebase), classified the
    /// same way as `rebase(onto:)`. Throws `PullError.noUpstream` when the
    /// current branch has no upstream tracking ref.
    func pull(worktreePath: URL) async throws -> MergeResult {
        guard let upstream = try await resolveUpstreamRef(worktreePath: worktreePath) else {
            throw PullError.noUpstream
        }
        // Upstream ref looks like "origin/<branch>"; strip the validated
        // "<remote>/" prefix to recover the branch name (same derivation as
        // `remoteForFetch`, but reusing `resolveUpstreamRef`'s already-validated
        // `remote` so it can't mis-split). Fetch it fresh, bypassing the
        // throttle the status probe uses.
        let branchName = String(upstream.ref.dropFirst(upstream.remote.count + 1))
        try await fetchRef(
            worktreePath: worktreePath,
            remote: upstream.remote,
            branch: branchName
        )
        return try await rebase(worktreePath: worktreePath, onto: upstream.ref)
    }
}

enum PullError: LocalizedError, Equatable {
    case noUpstream

    var errorDescription: String? {
        switch self {
        case .noUpstream:
            return "This branch has no upstream to pull from."
        }
    }
}
