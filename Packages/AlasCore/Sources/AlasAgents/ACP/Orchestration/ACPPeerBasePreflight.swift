import Foundation
import AlasPlatform

/// What the source knows about the parent's checkout when it must decide
/// whether a paired Mac can reproduce its code.
public struct ACPPeerBranchState: Equatable, Sendable {
    /// No uncommitted change, staged, unstaged or untracked.
    public let isClean: Bool
    public let head: String
    /// Nil when `HEAD` is detached.
    public let branch: String?
    /// The branch's upstream as a remote-tracking ref, such as `origin/fix/x`.
    public let upstream: String?
    /// What the local tracking ref for `upstream` points at; nothing is fetched.
    public let upstreamHead: String?
    /// The upstream's remote is the one named `origin`.
    public let upstreamOnOrigin: Bool

    public init(
        isClean: Bool, head: String, branch: String?, upstream: String?, upstreamHead: String?, upstreamOnOrigin: Bool
    ) {
        self.isClean = isClean
        self.head = head
        self.branch = branch
        self.upstream = upstream
        self.upstreamHead = upstreamHead
        self.upstreamOnOrigin = upstreamOnOrigin
    }
}

/// Code reaches a paired Mac through the git remote, so a new worktree there
/// may only branch from what the parent is really on.
public enum ACPPeerBasePreflight {
    public enum Decision: Equatable, Sendable {
        /// The base to send and, when the source vouches for it, the SHA the peer must find there.
        case useBase(String, expectedSHA: String?)
        case refuse(String)
    }

    private static let origin = "origin"

    public static func decide(explicitBase: String?, state: ACPPeerBranchState?) -> Decision {
        if let explicitBase { return .useBase(explicitBase, expectedSHA: nil) }
        guard let state else {
            return .refuse("Could not read the git state of this worktree. Code travels through the git remote, so pass --base.")
        }
        guard state.branch != nil else {
            return .refuse("HEAD is detached. Code travels through the git remote, so pass --base.")
        }
        guard state.isClean else {
            return .refuse("This worktree has uncommitted changes. Code travels through the git remote, so commit and push first, or pass --base.")
        }
        guard let upstream = state.upstream else {
            return .refuse("This branch has no upstream. Code travels through the git remote, so push first, or pass --base.")
        }
        let prefix = origin + "/"
        guard state.upstreamOnOrigin, upstream.hasPrefix(prefix), upstream.count > prefix.count else {
            return .refuse("The upstream \(upstream) is not on origin. Code travels through the git remote, so pass --base.")
        }
        guard state.upstreamHead == state.head else {
            return .refuse("HEAD differs from \(upstream). Code travels through the git remote, so push first, or pass --base.")
        }
        return .useBase(String(upstream.dropFirst(prefix.count)), expectedSHA: state.head)
    }

    /// Reads `worktree`'s state through `git`, which follows the project's
    /// host. Nil when git cannot answer.
    public static func branchState(worktreePath worktree: URL, git: GitService = GitService()) async -> ACPPeerBranchState? {
        guard let head = try? await git.revParseHEAD(worktreePath: worktree),
              let status = try? await Process.git(["status", "--porcelain"], cwd: worktree), status.exitCode == 0,
              let branch = try? await git.currentBranch(worktreePath: worktree)
        else { return nil }
        let upstream = try? await git.resolveUpstreamRef(worktreePath: worktree)
        var upstreamHead: String?
        if let upstream {
            let resolved = try? await Process.git(["rev-parse", "--verify", "-q", upstream.ref + "^{commit}"], cwd: worktree)
            if resolved?.exitCode == 0 {
                upstreamHead = resolved?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ACPPeerBranchState(
            isClean: status.stdout.isEmpty, head: head, branch: branch.isEmpty ? nil : branch,
            upstream: upstream?.ref, upstreamHead: upstreamHead, upstreamOnOrigin: upstream?.remote == origin
        )
    }
}
