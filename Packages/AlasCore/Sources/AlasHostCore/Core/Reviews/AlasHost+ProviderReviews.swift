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
