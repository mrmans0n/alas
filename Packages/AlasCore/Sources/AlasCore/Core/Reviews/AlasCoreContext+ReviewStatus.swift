import Foundation

extension AlasCoreContext {
    /// How often a followed worktree's review status is read again.
    static let reviewStatusRefreshInterval: Duration = .seconds(45)

    /// Counts a follower of worktree `worktreeID`'s review status; the first
    /// starts refreshing it.
    func followReviewStatus(_ worktreeID: String) {
        reviewFollowers[worktreeID, default: 0] += 1
        guard reviewFollowers[worktreeID] == 1 else { return }
        reviewRefreshes[worktreeID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // The context is not held while the loop waits.
                guard let pause = await self?.refreshFollowedReviewStatus(worktreeID) else { return }
                await pause(Self.reviewStatusRefreshInterval)
            }
        }
    }

    /// Reads worktree `worktreeID`'s review status once, and returns how to
    /// wait for the next read.
    private func refreshFollowedReviewStatus(_ worktreeID: String) async -> @MainActor (Duration) async -> Void {
        if let reviewStatusRefresh {
            await reviewStatusRefresh(worktreeID)
        } else {
            await refreshReviewStatus(worktreeID)
        }
        return reviewStatusPause
    }

    /// Forgets worktree `worktreeID`'s review status, as it is removed or
    /// archived. The loop stays: a right pane may still hold it.
    func forgetReviewStatus(_ worktreeID: String) {
        reviewLoops[worktreeID]?.forget()
    }

    /// Drops a follower; the last one stops the refresh.
    func unfollowReviewStatus(_ worktreeID: String) {
        guard let count = reviewFollowers[worktreeID] else { return }
        guard count <= 1 else {
            reviewFollowers[worktreeID] = count - 1
            return
        }
        reviewFollowers[worktreeID] = nil
        reviewRefreshes.removeValue(forKey: worktreeID)?.cancel()
    }

    /// Reads worktree `worktreeID`'s branch, changes and remotes, and its
    /// pull request and checks with them.
    // ponytail: an open right pane refreshes the same status from its own snapshot; both run while it is followed.
    func refreshReviewStatus(_ worktreeID: String) async {
        guard let (project, worktree) = projectAndWorktree(withWorktreeId: worktreeID), !project.isFolder else { return }
        let loop = reviewLoop(for: worktree, baseBranch: environment.configuration().worktrees.baseBranch)
        let git = GitService()
        let path = worktree.path
        // Read once: a base changed while the probes run is the next refresh's.
        let baseBranch = loop.currentBaseBranch
        // Begun before the probes, so a base change or a forget while they
        // run discards what they read.
        let inspection = loop.beginLocalInspection()
        do {
            async let branch = git.currentBranch(worktreePath: path)
            async let head = git.revParseHEAD(worktreePath: path)
            async let changes = git.status(worktreePath: path)
            async let upstream = try? git.resolveUpstreamRef(worktreePath: path)
            async let needsPush = (try? git.needsPush(worktreePath: path)) ?? true
            async let upstreamAhead = (try? git.upstreamAheadCommitCount(worktreePath: path)) ?? 0
            async let ahead = try? git.branchCommitCount(worktreePath: path, baseBranch: baseBranch)
            async let remotes = git.remotes(worktreePath: path)
            let resolvedUpstream = await upstream
            let files = try await changes
            let local = ReviewLoopLocalState(
                branchName: try await branch,
                headSHA: try await head,
                baseBranch: baseBranch,
                hasWorkingTreeChanges: !files.isEmpty,
                hasStagedChanges: files.contains { $0.stage == .staged },
                aheadCommitCount: await ahead?.count ?? 0,
                hasUpstream: resolvedUpstream != nil,
                upstreamRemoteName: resolvedUpstream?.remote,
                upstreamBranchName: resolvedUpstream.map { String($0.ref.dropFirst($0.remote.count + 1)) },
                upstreamAheadCommitCount: await upstreamAhead,
                needsPush: await needsPush
            )
            let resolvedRemotes = try await remotes
            guard let attempt = loop.beginLocalRefresh(from: inspection, local: local) else { return }
            await loop.refresh(attempt, remotes: resolvedRemotes)
        } catch {
            // The next round reads it again.
            loop.cancelLocalRefresh(inspection)
        }
    }
}
