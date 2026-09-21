import Foundation

/// Picks the branch and destination a composed schedule creates.
///
/// A candidate is free only when *both* its path and its branch are. The path
/// alone is not enough: `WorktreeService.add` checks an already existing
/// branch out at its own tip instead of branching from the base, so a
/// retained branch — one whose worktree was removed, or that an automatic
/// `git branch -d` refused to delete because it was unmerged — would silently
/// run the schedule against stale code.
///
/// Neither answer is read off this Mac here, because for an SSH project
/// neither lives here: the destination is a path on the remote host's
/// filesystem, and the branches are the remote repository's. The caller
/// supplies both, already resolved against the project's host.
enum ScheduledWorktreeDestination {
    enum PathState: Equatable, Sendable {
        case free
        case occupied
        /// The host could not be asked — an SSH probe that failed rather than
        /// answered. Distinct from `occupied` because guessing either way is
        /// wrong: claiming the path risks overwriting, skipping it burns a
        /// name per candidate for as long as the host stays unreachable.
        case unknown
    }

    enum Outcome: Equatable {
        case free(branch: String, destination: URL)
        /// Every candidate up to the limit is taken, which means the user has
        /// old scheduled worktrees to clean up.
        case exhausted
        /// A candidate's path state could not be determined, so nothing can
        /// be claimed safely.
        case undeterminable(URL)
    }

    /// Whether `destination` is already taken, asked of the host that will
    /// run `git worktree add` there. For an SSH project that is the remote
    /// filesystem: this Mac has no opinion about a path it cannot see, and
    /// answering from `FileManager` would report every remote destination
    /// free.
    static func existence(of destination: URL, onHost host: String?) async -> PathState {
        guard let host else {
            return FileManager.default.fileExists(atPath: destination.path) ? .occupied : .free
        }
        switch await RemoteFileAccess.existence(host: host, path: destination.path) {
        case .exists: return .occupied
        case .missing: return .free
        case .unknown: return .unknown
        }
    }

    /// The rendered branch when it is free, else the same name with the
    /// smallest numeric suffix that is.
    static func firstFree(
        rendered: String,
        pathTemplate: String,
        worktreeRoot: String,
        repoName: String,
        existingBranches: Set<String>,
        limit: Int = 50,
        pathState: @Sendable (URL) async -> PathState
    ) async -> Outcome {
        for attempt in 0..<limit {
            let branch = attempt == 0 ? rendered : "\(rendered)-\(attempt + 1)"
            guard case .valid = GitNameValidator.validateBranchName(branch) else { continue }
            guard !existingBranches.contains(branch) else { continue }
            let destination = WorktreePathTemplateRenderer.render(
                template: pathTemplate,
                worktreeRoot: worktreeRoot,
                repoName: repoName,
                branch: branch
            )
            switch await pathState(destination) {
            case .free:
                return .free(branch: branch, destination: destination)
            case .occupied:
                continue
            case .unknown:
                return .undeterminable(destination)
            }
        }
        return .exhausted
    }
}
