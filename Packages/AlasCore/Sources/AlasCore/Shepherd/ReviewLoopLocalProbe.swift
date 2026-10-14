import Foundation

/// Builds the `ReviewLoopLocalState` the review loop needs, for callers that
/// have no Changes pane: the PR shepherd and `pr_status`. `RightPaneState`
/// keeps its own assembly because it shares these probes with the file tree
/// refresh.
public struct ReviewLoopLocalProbe: Sendable {
    public var probe: @Sendable (_ worktreePath: URL, _ baseBranch: String) async throws -> (local: ReviewLoopLocalState, remotes: [GitRemote])

    public init(
        probe: @escaping @Sendable (_ worktreePath: URL, _ baseBranch: String) async throws -> (local: ReviewLoopLocalState, remotes: [GitRemote])
    ) {
        self.probe = probe
    }

    /// The fields `RightPaneState.refreshReviewLoop` fills, from the same
    /// `GitService` probes, without the file tree and stash work the pane
    /// also does. The ahead count uses the review-loop base resolution
    /// (`origin/<base>` first). Unlike the pane, a status or HEAD read that
    /// fails throws, so a broken worktree backs off instead of reading as a
    /// clean, unborn branch. The other probes keep the pane's fallbacks:
    /// `needsPush` true, upstream-ahead 0, no upstream, no remotes.
    public static let live = ReviewLoopLocalProbe { worktreePath, baseBranch in
        let git = GitService()
        async let status = git.status(worktreePath: worktreePath)
        async let head = git.revParseHEAD(worktreePath: worktreePath)
        async let branch = git.currentBranch(worktreePath: worktreePath)
        async let ahead = git.commitsAhead(at: worktreePath, baseBranch: baseBranch, resolution: .baseOriginFirst)
        async let upstream = git.resolveUpstreamRef(worktreePath: worktreePath)
        async let remotes = git.remotes(worktreePath: worktreePath)
        async let needsPush = git.needsPush(worktreePath: worktreePath)
        async let upstreamAhead = git.upstreamAheadCommitCount(worktreePath: worktreePath)
        let changes = try await status
        let headSHA = try await head
        let resolvedUpstream = try? await upstream
        let local = ReviewLoopLocalState(
            branchName: (try? await branch) ?? "",
            headSHA: headSHA,
            baseBranch: baseBranch,
            hasWorkingTreeChanges: !changes.isEmpty,
            hasStagedChanges: changes.contains { $0.stage == .staged },
            aheadCommitCount: (try? await ahead)?.commits.count ?? 0,
            hasUpstream: resolvedUpstream != nil,
            upstreamRemoteName: resolvedUpstream?.remote,
            upstreamBranchName: resolvedUpstream.map { String($0.ref.dropFirst($0.remote.count + 1)) },
            upstreamAheadCommitCount: (try? await upstreamAhead) ?? 0,
            needsPush: (try? await needsPush) ?? true
        )
        return (local: local, remotes: (try? await remotes) ?? [])
    }
}
