import Foundation
import AlasFoundation
import AlasModel
import AlasFeatures
import AlasIntegrations

extension ReviewsAPI {
    /// Pull or merge request review `sessionID` of the worktree as its
    /// provider shows it to the host's user, with its diff when `withDiff`.
    public func providerReview(_ sessionID: String, in worktree: Worktree, withDiff: Bool) async throws -> HostProviderReview {
        let (record, remote, provider) = try providerSession(sessionID, in: worktree)
        guard case .reviewRequest(_, _, _, let number, _) = record.target.payload else {
            throw HostError.invalidRequest(reason: "This review has no pull or merge request.")
        }
        do {
            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
            let diff = withDiff
                ? HostProviderReview.capped(try await provider.reviewDiff(remote: remote, request: request, cwd: worktree.path))
                : nil
            return HostProviderReview(
                remote: remote,
                request: request,
                capabilities: provider.capabilities,
                account: await provider.viewerLogin(remote: remote, cwd: worktree.path),
                diff: diff?.diff,
                diffTruncated: diff?.truncated ?? false
            )
        } catch {
            throw HostError.failed(message: error.localizedDescription)
        }
    }

    /// Opens the review of the worktree's pull or merge request `number`,
    /// reusing the open one, as an agent would.
    public func openProviderReview(number: Int, in worktree: Worktree, caller: HostCaller) async throws -> HostReview {
        caller.log("reviews.openProvider", "\(number)")
        guard number > 0 else { throw HostError.invalidRequest(reason: "A pull or merge request number starts at 1.") }
        switch await open("\(number)", in: worktree, caller: caller) {
        case .failure(let failure):
            throw HostError.failed(message: failure.message)
        case .success(let opened):
            return try read(opened.record.target.draftSessionID.rawValue, in: worktree)
        }
    }

    /// The saved PR session `sessionID` of `worktree`, its remote and provider.
    private func providerSession(
        _ sessionID: String, in worktree: Worktree
    ) throws -> (record: ReviewSessionRecord, remote: CodeHostRemote, provider: any CodeHostProvider) {
        guard let parsed = ReviewDraftSessionID(rawValue: sessionID), parsed.isFor(worktreeID: worktree.id),
              let record = try list(in: worktree).first(where: { $0.sessionID == sessionID })?.record
        else { throw HostError.notFound(what: "review \(sessionID)") }
        guard record.target.kind == .reviewRequest, let remote = record.target.providerRemote else {
            throw HostError.invalidRequest(reason: "This review has no pull or merge request.")
        }
        guard let provider = core.codeHostProviders.provider(for: remote.kind) else {
            throw HostError.failed(message: CodeHostProviderError.unsupportedProvider(remote.kind).localizedDescription)
        }
        return (record, remote, provider)
    }
}

extension AlasCoreContext {
    /// The path renamed file `path` had before in pull or merge request
    /// review `session`, from its provider diff (loaded once per review);
    /// nil on any failure, which files the comment without it.
    public func providerReviewOriginalPath(_ session: ReviewDraftSessionID, path: String) async -> String? {
        if let files = providerReviewFiles[session] { return files.first { $0.path == path }?.originalPath }
        // Hidden worktrees too: an agent can comment from one.
        let worktrees = projects.projects.flatMap { projects.worktrees(projectId: $0.id) }
        guard let worktree = worktrees.first(where: { session.isFor(worktreeID: $0.id) }),
              let record = try? reviewSessions.list(worktreeID: worktree.id)
              .first(where: { $0.target.draftSessionID == session }),
              case .reviewRequest(_, _, _, let number, _) = record.target.payload,
              // The session's own remote, so no other repository's PR of the
              // same number can stamp a path.
              let remote = record.target.providerRemote,
              let provider = codeHostProviders.provider(for: remote.kind) else { return nil }
        do {
            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
            let files = try await ReviewRequestDiffLoader(provider: provider)
                .load(remote: remote, request: request, cwd: worktree.path).summary.files
            providerReviewFiles[session] = files
            return files.first { $0.path == path }?.originalPath
        } catch {
            return nil
        }
    }
}
