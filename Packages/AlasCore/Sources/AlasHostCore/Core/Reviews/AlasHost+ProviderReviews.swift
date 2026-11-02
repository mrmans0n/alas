import Foundation
import AlasFoundation
import AlasModel
import AlasFeatures
import AlasIntegrations
import AlasPlatform

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
            // Its images are read at the head of the diff a Mac now shows.
            if let diff {
                core.providerReviewImages[record.target.draftSessionID] = ProviderReviewImages(
                    request: request, paths: ReviewRequestDiffLoader.imagePaths(in: diff.diff))
            }
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

    /// Replies to, resolves or unresolves thread `threadID` of pull or merge
    /// request review `sessionID` on its provider, as the host's user.
    public func mutateThread(
        _ threadID: String, kind: ProviderThreadMutationKind, body: String?,
        sessionID: String, in worktree: Worktree, caller: HostCaller
    ) async throws -> ProviderThreadMutationResult {
        caller.log("reviews.thread", "\(sessionID) \(threadID) \(kind.rawValue)")
        let (record, remote, provider) = try providerSession(sessionID, in: worktree)
        try Self.checkSize(body ?? "")
        guard case .reviewRequest(_, _, _, let number, _) = record.target.payload else {
            throw HostError.invalidRequest(reason: "This review has no pull or merge request.")
        }
        let request: ReviewRequest
        do {
            request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
        } catch {
            throw HostError.failed(message: error.localizedDescription)
        }
        // Only a thread of this pull request: a Mac must not reach another's.
        guard let thread = request.threads.first(where: { $0.id == threadID }) else {
            throw HostError.notFound(what: "review thread \(threadID)")
        }
        // Both providers read only `providerThreadID`.
        let summary = ReviewThreadSummary(
            id: thread.id, author: thread.author, body: thread.body, url: thread.url,
            isResolved: thread.isResolved, isActionable: thread.isActionable, providerThreadID: thread.id
        )
        do {
            let result = try await provider.mutateReviewThread(ProviderThreadMutation(
                remote: remote, reviewRequest: request, thread: summary, kind: kind, bodyMarkdown: body, cwd: worktree.path
            ))
            didChange(worktreeID: worktree.id)
            return result
        } catch {
            throw HostError.failed(message: error.localizedDescription)
        }
    }

    /// Publishes pull or merge request review `sessionID` on its provider, as
    /// the host's user: its unpublished drafts, or only `publish.draftIDs`,
    /// pinned to the head the Mac showed. One publish per review at a time.
    public func publish(
        _ publish: HostReviewPublish, sessionID: String, in worktree: Worktree, caller: HostCaller
    ) async throws -> ProviderReviewPublishResult {
        caller.log("reviews.publish", "\(sessionID) \(publish.decision.rawValue)")
        let (record, remote, provider) = try providerSession(sessionID, in: worktree)
        try Self.checkSize(publish.body)
        if let head = publish.headSHA, !RemoteWorktreeFileAccess.isCommitSHA(head) {
            throw HostError.invalidRequest(reason: "The head commit must be a commit SHA.")
        }
        guard case .reviewRequest(_, _, _, let number, _) = record.target.payload else {
            throw HostError.invalidRequest(reason: "This review has no pull or merge request.")
        }
        guard core.publishingReviews.insert(sessionID).inserted else {
            throw HostError.invalidRequest(reason: "This review is already being published.")
        }
        defer { core.publishingReviews.remove(sessionID) }
        let session = record.target.draftSessionID
        let drafts = core.reviewDrafts
        var providerCalled = false
        // A failure after the provider posted (e.g. a draft save) still changed the review.
        defer { if providerCalled { didChange(worktreeID: worktree.id) } }
        do {
            let request = try await provider.reviewRequest(remote: remote, number: number, cwd: worktree.path)
                .pinned(headSHA: publish.headSHA)
            providerCalled = true
            // Only this session's drafts, so a Mac can't select another's.
            let result = try await ProviderReviewPublisher.publish(
                try drafts.load(sessionID: session), selecting: publish.draftIDs.map(Set.init), to: request,
                remote: remote, decision: publish.decision, summaryBody: publish.body, cwd: worktree.path,
                provider: provider, now: Date.init
            ) { draftID, outcome in
                guard var draft = try drafts.load(sessionID: session).first(where: { $0.id == draftID }) else { return }
                switch outcome {
                case .published(let published):
                    draft.providerPublish = published
                    draft.providerError = nil
                    draft.updatedAt = published.publishedAt
                case .failed(let error):
                    draft.providerError = error
                    draft.updatedAt = error.occurredAt
                }
                try drafts.save(draft)
            }
            return result
        } catch let error as ProviderReviewPublishError {
            throw HostError.invalidRequest(reason: error.localizedDescription)
        } catch {
            throw HostError.failed(message: error.localizedDescription)
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
    /// The commits pull or merge request review `session` of `worktree`
    /// compares in an image diff, as its provider names them to this host
    /// for the diff it last served, at `head`: asked once per diff read,
    /// a failure included.
    func providerReviewImageRevisions(
        _ session: ReviewDraftSessionID, head: String, in worktree: Worktree
    ) async throws -> CodeHostReviewImageRevisions {
        let (remote, provider) = try providerReviewSource(session, in: worktree)
        guard var images = providerReviewImages[session] else {
            throw HostError.failed(message: "This review's diff isn't loaded on the host. Reload it and try again.")
        }
        // Compared, never passed to git: only the provider's commits are.
        guard images.request.headSHA == head else {
            throw HostError.failed(message: "This pull request changed since it was loaded. Reload it and try again.")
        }
        let revisions: Task<CodeHostReviewImageRevisions, any Error>
        if let inFlight = images.revisions {
            revisions = inFlight
        } else {
            let request = images.request, cwd = worktree.path
            revisions = Task { try await provider.reviewImageRevisions(remote: remote, request: request, cwd: cwd) }
            images.revisions = revisions
            providerReviewImages[session] = images
        }
        do {
            return try await revisions.value
        } catch {
            throw HostError.failed(message: error.localizedDescription)
        }
    }

    /// The saved remote of pull or merge request review `session` of
    /// `worktree`, and its provider.
    func providerReviewSource(
        _ session: ReviewDraftSessionID, in worktree: Worktree
    ) throws -> (CodeHostRemote, any CodeHostProvider) {
        guard session.isFor(worktreeID: worktree.id),
              let record = try reviewSessions.list(worktreeID: worktree.id)
              .first(where: { $0.target.draftSessionID == session }),
              case .reviewRequest = record.target.payload,
              let remote = record.target.providerRemote,
              let provider = codeHostProviders.provider(for: remote.kind)
        else { throw HostError.notFound(what: "review \(session.rawValue)") }
        return (remote, provider)
    }

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

/// A pull or merge request review's request as the host served its diff,
/// that diff's image paths, and the image diff commits its provider names
/// for it once asked.
struct ProviderReviewImages {
    let request: ReviewRequest
    let paths: (after: Set<String>, before: Set<String>)
    var revisions: Task<CodeHostReviewImageRevisions, any Error>?
}
