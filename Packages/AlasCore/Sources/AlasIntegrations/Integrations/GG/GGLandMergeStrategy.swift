import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// How `gg land` merges a stack's entries.
public enum GGLandMergeStrategy: Equatable, Sendable {
    /// gg's defaults: squash each entry, and rebase the rest of the stack
    /// after every merge.
    case squashAndRebase
    /// Merge commits, rebasing the rest of the stack only when the next entry
    /// can't merge as it is. Each skipped rebase spares the remaining entries
    /// a push and a CI run.
    case mergeCommitsRebaseIfNeeded

    /// What the strategy adds to `gg land`.
    public var landArguments: [String] {
        switch self {
        case .squashAndRebase: []
        case .mergeCommitsRebaseIfNeeded: ["--no-squash", "--rebase-if-needed"]
        }
    }

    /// Merge commits only when gg supports `--rebase-if-needed` and the
    /// repository takes a merge-commit landing as it is. Without the flag,
    /// `--no-squash` alone does not help: older gg can't stop a GitLab
    /// project that squashes by default, and still rebases every entry.
    /// Unknown settings keep gg's defaults.
    public static func decide(supportsRebaseIfNeeded: Bool, settings: CodeHostMergeSettings?) -> Self {
        guard supportsRebaseIfNeeded, let settings else { return .squashAndRebase }
        switch settings {
        case .gitLab(let mergeMethod, let squashOption):
            // "rebase_merge" and "ff" only merge a branch that is up to date
            // with the base, so every entry would need a rebase anyway.
            return mergeMethod == "merge" && squashOption != "always" ? .mergeCommitsRebaseIfNeeded : .squashAndRebase
        case .gitHub(let allowsMergeCommit, let requiresLinearHistory, let allowedMergeMethods):
            let rulesAllowMerge = allowedMergeMethods?.contains("merge") ?? true
            return allowsMergeCommit && !requiresLinearHistory && rulesAllowMerge
                ? .mergeCommitsRebaseIfNeeded : .squashAndRebase
        }
    }

    /// The merge settings of the forge the worktree at `worktreePath`
    /// pushes to, for landing onto `base` (a branch, optionally prefixed
    /// with its remote). Nil when the remote, its provider, or the settings
    /// can't be read.
    public static func loadMergeSettings(
        worktreePath: String,
        base: String,
        registry: CodeHostProviderRegistry = .live()
    ) async -> CodeHostMergeSettings? {
        let cwd = URL(fileURLWithPath: worktreePath)
        guard let remotes = try? await GitService().remotes(worktreePath: cwd),
              let remote = CodeHostRemoteDetector.detect(
                  from: remotes,
                  supportedKinds: registry.supportedKinds,
                  preferredRemoteName: CodeHostRemoteDetector.preferredRemoteName(forBaseBranch: base, remotes: remotes)
              ),
              let provider = registry.provider(for: remote.kind)
        else { return nil }
        let prefix = "\(remote.remoteName)/"
        let branch = base.hasPrefix(prefix) ? String(base.dropFirst(prefix.count)) : base
        return try? await provider.mergeSettings(remote: remote, baseBranch: branch, cwd: cwd)
    }
}
