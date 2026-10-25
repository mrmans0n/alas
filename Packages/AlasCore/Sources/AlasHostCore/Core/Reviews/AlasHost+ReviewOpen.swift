import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents
import AlasIntegrations

/// A review session `ReviewsAPI.open` saved, for the presenter to show.
public struct OpenedReview: Sendable {
    public let record: ReviewSessionRecord
    /// How the CLI names the review in its reply.
    public let label: String
}

/// Why a review target could not be opened, in the CLI's words.
public struct ReviewOpenFailure: Error, Equatable {
    public let message: String
}

extension ReviewsAPI {
    /// Resolves `target` (a PR/MR number or URL, a commit range, a branch or
    /// a revision) in `worktree` and saves its review session, reusing the
    /// active one for the same target.
    public func open(_ target: String, in worktree: Worktree, caller: HostCaller) async -> Result<OpenedReview, ReviewOpenFailure> {
        caller.log("reviews.open", target)
        guard let parsed = AlasCLIReviewTargetResolver.parse(target) else {
            return .failure(.init(message:
                "unsupported review target '\(target)' — expected a PR/MR number or URL, "
                    + "a commit range (base..head or base...head), a branch, or a revision"
            ))
        }
        let resolved: Result<(ReviewSessionTarget, String), ReviewOpenFailure>
        switch parsed {
        case .number, .url:
            resolved = await providerTarget(parsed, label: target, in: worktree)
        case .range(let base, let head, let threeDot):
            resolved = await rangeTarget(base: base, head: head, threeDot: threeDot, in: worktree)
        case .revision(let ref):
            resolved = await revisionTarget(ref, in: worktree)
        }
        return resolved.flatMap { reviewTarget, label in
            let store = core.reviewSessions
            var saved: ReviewSessionRecord?
            var isNew = false
            ReviewSessionLauncher.openOrFocus(
                target: reviewTarget,
                findActive: {
                    let active = try store.findActive(targetID: $0)
                    isNew = active == nil
                    return active
                },
                save: { try store.save($0) },
                open: { saved = $0 }
            )
            guard let saved else { return .failure(.init(message: "could not open review session")) }
            didChange(worktreeID: worktree.id)
            if isNew { noticeOpened(in: worktree, label: label, sessionID: saved.target.draftSessionID.rawValue) }
            return .success(OpenedReview(record: saved, label: label))
        }
    }

    private func providerTarget(
        _ parsed: AlasCLIReviewTargetResolver.Target,
        label: String,
        in worktree: Worktree
    ) async -> Result<(ReviewSessionTarget, String), ReviewOpenFailure> {
        do {
            let registry = core.codeHostProviders
            let supportedRemotes = try await core.supportedReviewRemotes(for: worktree, registry: registry)
            guard !supportedRemotes.isEmpty else {
                return .failure(.init(message: "no code host remote found for this worktree"))
            }
            let remote: CodeHostRemote
            let number: Int
            switch parsed {
            case .number(let value):
                remote = supportedRemotes[0]
                number = value
            case .url(let host, let repositorySlug, let value):
                guard let matchingRemote = supportedRemotes.first(where: {
                    $0.host == host && $0.repositorySlug.lowercased() == repositorySlug.lowercased()
                }) else {
                    return .failure(.init(message: "review URL does not match this worktree's remote"))
                }
                remote = matchingRemote
                number = value
            case .range, .revision:
                return .failure(.init(message: "commit ranges and revisions are not supported yet"))
            }
            guard let provider = registry.provider(for: remote.kind) else {
                return .failure(.init(message: "\(remote.kind.displayName) is not supported yet."))
            }
            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
            return .success((.reviewRequest(
                worktreeID: worktree.id,
                repositoryPath: worktree.path,
                provider: request.provider,
                host: request.remote.host,
                repositorySlug: request.remote.repositorySlug,
                number: request.number,
                url: request.url,
                title: request.title,
                headSHA: request.headSHA
            ), label))
        } catch {
            return .failure(.init(message: Self.describe(error)))
        }
    }

    private func rangeTarget(
        base: String,
        head: String,
        threeDot: Bool,
        in worktree: Worktree
    ) async -> Result<(ReviewSessionTarget, String), ReviewOpenFailure> {
        let git = GitService()
        let baseSHA: String
        let headSHA: String
        do {
            // Three-dot ranges compute a real merge base downstream and have
            // no root-commit special case; two-dot ranges reuse the same
            // empty-tree fallback the range diff loaders already rely on
            // (`resolveTwoDotLeftTree`), so a root commit's "HEAD^..HEAD"
            // resolves instead of failing before the review ever opens.
            baseSHA = threeDot
                ? try await git.resolveRevision(at: worktree.path, ref: base)
                : try await git.resolveTwoDotLeftTree(worktreePath: worktree.path, base: base)
        } catch {
            return .failure(.init(message: "could not resolve '\(base)' in worktree '\(worktree.branch)'"))
        }
        do {
            headSHA = try await git.resolveRevision(at: worktree.path, ref: head)
        } catch {
            return .failure(.init(message: "could not resolve '\(head)' in worktree '\(worktree.branch)'"))
        }
        let title = "Review \(base)\(threeDot ? "..." : "..")\(head)"
        // Three-dot ranges diff from the merge base — exactly what the
        // `.branch` target's loader does; two-dot ranges are plain range
        // diffs via `.commitRange`.
        let reviewTarget: ReviewSessionTarget = threeDot
            ? .branch(worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA, title: title)
            : .commitRange(worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA, title: title)
        return .success((reviewTarget, title))
    }

    private func revisionTarget(_ ref: String, in worktree: Worktree) async -> Result<(ReviewSessionTarget, String), ReviewOpenFailure> {
        let git = GitService()
        let localBranches = (try? await git.localBranches(at: worktree.path)) ?? []
        if localBranches.contains(ref) {
            // The named branch is the HEAD; the repository's configured base
            // branch is the BASE — this reviews "`ref`'s changes vs the
            // base". The palette's branch picker (ReviewScopeSelection
            // .target(for: .branch)) reviews the opposite direction ("my
            // current HEAD vs the picked branch"). Both are intentional for
            // their own entry point; do not "fix" one to match the other
            // without an explicit design decision — see
            // docs/superpowers/specs/2026-07-16-review-target-palette-design.md.
            //
            // Pinned to SHAs so the stored session survives branch movement.
            let baseName = core.environment.configuration().worktrees.baseBranch
            do {
                let headSHA = try await git.resolveRevision(at: worktree.path, ref: ref)
                let baseSHA: String
                if let originSHA = try? await git.resolveRevision(at: worktree.path, ref: "origin/\(baseName)") {
                    baseSHA = originSHA
                } else {
                    baseSHA = try await git.resolveRevision(at: worktree.path, ref: baseName)
                }
                let title = "Review \(ref) against \(baseName)"
                return .success((
                    .branch(worktreeID: worktree.id, repositoryPath: worktree.path, base: baseSHA, head: headSHA, title: title),
                    title
                ))
            } catch {
                return .failure(.init(message: "could not resolve base '\(baseName)' for branch '\(ref)'"))
            }
        }
        guard let sha = try? await git.resolveRevision(at: worktree.path, ref: ref) else {
            return .failure(.init(message:
                "could not resolve review target '\(ref)' in worktree '\(worktree.branch)' "
                    + "(not a PR number/URL, local branch, or revision)"
            ))
        }
        let short = String(sha.prefix(7))
        return .success((
            .commit(worktreeID: worktree.id, repositoryPath: worktree.path, sha: sha, title: "Review commit \(short)"),
            "commit \(short)"
        ))
    }

    nonisolated private static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

extension AlasCoreContext {
    /// Supported code-host remotes for `worktree`, the one its review's base
    /// branch tracks first.
    public func supportedReviewRemotes(
        for worktree: Worktree,
        registry: CodeHostProviderRegistry
    ) async throws -> [CodeHostRemote] {
        let remotes = try await GitService().remotes(worktreePath: worktree.path)
        let base = reviewLoop(for: worktree, baseBranch: environment.configuration().worktrees.baseBranch).currentBaseBranch
        // The right pane compares a worktree on the base branch itself with
        // that branch's origin, and so prefers origin's remote.
        let comparisonBase = !base.isEmpty && worktree.branch == base ? "origin/\(base)" : base
        return CodeHostRemoteDetector.detectAll(
            from: remotes,
            supportedKinds: registry.supportedKinds,
            preferredRemoteName: CodeHostRemoteDetector.preferredRemoteName(forBaseBranch: comparisonBase, remotes: remotes)
        )
    }
}
