import Foundation
import Observation

struct ReviewLoopRefreshAttempt: Equatable, Sendable {
    let local: ReviewLoopLocalState?
    fileprivate let generation: Int
}

enum ReviewMergeOutcome: Equatable, Sendable {
    case merged
    case queued
}

@Observable
@MainActor
final class ReviewLoopState {
    private let worktreePath: URL
    private var baseBranch: String
    private let providerRegistry: CodeHostProviderRegistry
    private(set) var refreshGeneration: Int = 0

    private(set) var snapshot: ReviewLoopSnapshot?
    private(set) var isRefreshing: Bool = false
    private(set) var isExpanded: Bool = false
    private(set) var lastError: String?
    private(set) var inFlightAction: ReviewReadinessActionKind?

    init(
        worktreePath: URL,
        baseBranch: String,
        providerRegistry: CodeHostProviderRegistry = .live()
    ) {
        self.worktreePath = worktreePath
        self.baseBranch = baseBranch
        self.providerRegistry = providerRegistry
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    /// The base branch currently used for review lookup/creation.
    var currentBaseBranch: String { baseBranch }

    func updateBaseBranch(_ branch: String) {
        guard branch != baseBranch else { return }
        baseBranch = branch
        refreshGeneration += 1
        isRefreshing = false
        snapshot = nil
        lastError = nil
    }

    func beginAction(_ action: ReviewReadinessActionKind) -> Bool {
        guard inFlightAction == nil else { return false }
        inFlightAction = action
        return true
    }

    func endAction(_ action: ReviewReadinessActionKind) {
        guard inFlightAction == action else { return }
        inFlightAction = nil
    }

    func beginLocalInspection() -> ReviewLoopRefreshAttempt {
        beginRefresh(local: nil)
    }

    func beginLocalRefresh(local: ReviewLoopLocalState) -> ReviewLoopRefreshAttempt {
        beginRefresh(local: local)
    }

    func beginLocalRefresh(
        from inspection: ReviewLoopRefreshAttempt,
        local: ReviewLoopLocalState
    ) -> ReviewLoopRefreshAttempt? {
        guard isCurrentRefresh(inspection.generation) else { return nil }
        return beginRefresh(local: local)
    }

    private func beginRefresh(local: ReviewLoopLocalState?) -> ReviewLoopRefreshAttempt {
        refreshGeneration += 1
        let generation = refreshGeneration

        isRefreshing = true
        lastError = nil
        return ReviewLoopRefreshAttempt(local: local, generation: generation)
    }

    func failLocalRefresh(_ attempt: ReviewLoopRefreshAttempt, error: Error) {
        guard isCurrentRefresh(attempt.generation) else { return }

        let message = Self.describe(error)
        lastError = message
        refreshGeneration += 1
        isRefreshing = false
        if let local = attempt.local {
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: nil,
                reviewRequest: nil,
                providerAvailable: false,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: message
            )
        } else {
            snapshot = nil
        }
    }

    func finishLocalRefresh(
        _ attempt: ReviewLoopRefreshAttempt,
        preservingRemoteWith local: ReviewLoopLocalState
    ) {
        guard isCurrentRefresh(attempt.generation) else { return }

        let current = snapshot
        let local = Self.preservingHeadRemote(in: local, from: current?.local)
        snapshot = ReviewLoopSnapshot(
            local: local,
            remote: current?.remote,
            reviewRequest: current?.reviewRequest,
            providerAvailable: current?.providerAvailable ?? false,
            providerAuthenticated: current?.providerAuthenticated ?? false,
            providerCapabilities: current?.providerCapabilities ?? .readOnly,
            errorMessage: current?.errorMessage
        )
        isRefreshing = false
    }

    private static func preservingHeadRemote(
        in local: ReviewLoopLocalState,
        from current: ReviewLoopLocalState?
    ) -> ReviewLoopLocalState {
        guard let current,
              local.headRemoteName == nil,
              local.headRemoteOwner == nil,
              local.branchName == current.branchName,
              local.headSHA == current.headSHA,
              local.baseBranch == current.baseBranch,
              (current.headRemoteName != nil || current.headRemoteOwner != nil)
        else {
            return local
        }

        return ReviewLoopLocalState(
            branchName: local.branchName,
            headSHA: local.headSHA,
            baseBranch: local.baseBranch,
            hasWorkingTreeChanges: local.hasWorkingTreeChanges,
            hasStagedChanges: local.hasStagedChanges,
            aheadCommitCount: local.aheadCommitCount,
            hasUpstream: local.hasUpstream,
            upstreamRemoteName: local.upstreamRemoteName,
            upstreamBranchName: local.upstreamBranchName,
            headRemoteName: current.headRemoteName,
            headRemoteOwner: current.headRemoteOwner,
            upstreamAheadCommitCount: local.upstreamAheadCommitCount,
            needsPush: local.needsPush
        )
    }

    func refresh(local: ReviewLoopLocalState, remotes: [GitRemote]) async {
        let attempt = beginLocalRefresh(local: local)
        await refresh(attempt, remotes: remotes)
    }

    func refresh(_ attempt: ReviewLoopRefreshAttempt, remotes: [GitRemote]) async {
        guard isCurrentRefresh(attempt.generation) else { return }
        guard let baseLocal = attempt.local else {
            isRefreshing = false
            return
        }
        let generation = attempt.generation

        defer {
            if isCurrentRefresh(generation) {
                isRefreshing = false
            }
        }

        guard !baseLocal.branchName.isEmpty else {
            snapshot = ReviewLoopSnapshot(
                local: baseLocal,
                remote: nil,
                reviewRequest: nil,
                providerAvailable: false,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: "No branch checked out."
            )
            return
        }

        guard !baseLocal.headSHA.isEmpty else {
            snapshot = ReviewLoopSnapshot(
                local: baseLocal,
                remote: nil,
                reviewRequest: nil,
                providerAvailable: false,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: "No commits yet."
            )
            return
        }

        let supportedKinds = providerRegistry.supportedKinds
        let preferredRemoteName = CodeHostRemoteDetector.preferredRemoteName(
            forBaseBranch: baseLocal.baseBranch,
            remotes: remotes
        )
        guard let remote = CodeHostRemoteDetector.detect(
            from: remotes,
            supportedKinds: supportedKinds.isEmpty ? nil : supportedKinds,
            preferredRemoteName: preferredRemoteName
        ) else {
            guard isCurrentRefresh(generation) else { return }
            snapshot = ReviewLoopSnapshot(
                local: baseLocal,
                remote: nil,
                reviewRequest: nil,
                providerAvailable: false,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: nil
            )
            return
        }
        let local = Self.withHeadRemote(baseLocal, remotes: remotes, baseRemote: remote)

        guard let provider = providerRegistry.provider(for: remote.kind) else {
            guard isCurrentRefresh(generation) else { return }
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: remote,
                reviewRequest: nil,
                providerAvailable: false,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: nil
            )
            return
        }

        let providerAvailable = await provider.isAvailable(cwd: worktreePath)
        guard isCurrentRefresh(generation) else { return }
        guard providerAvailable else {
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: remote,
                reviewRequest: nil,
                providerAvailable: false,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: nil
            )
            return
        }

        let providerAuthenticated = await provider.isAuthenticated(remote: remote, cwd: worktreePath)
        guard isCurrentRefresh(generation) else { return }
        guard providerAuthenticated else {
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: remote,
                reviewRequest: nil,
                providerAvailable: true,
                providerAuthenticated: false,
                providerCapabilities: .readOnly,
                errorMessage: nil
            )
            return
        }

        do {
            let request = try await provider.currentReviewRequest(
                remote: remote,
                branch: local.branchName,
                headOwner: local.headRemoteOwner,
                baseBranch: local.baseBranch,
                cwd: worktreePath
            )
            guard isCurrentRefresh(generation) else { return }
            let loadedRequest: ReviewRequest?
            if let request {
                let checks = try await provider.checks(remote: remote, request: request, cwd: worktreePath)
                guard isCurrentRefresh(generation) else { return }
                loadedRequest = request.withChecks(checks)
            } else {
                loadedRequest = nil
            }

            guard isCurrentRefresh(generation) else { return }
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: remote,
                reviewRequest: loadedRequest,
                providerAvailable: true,
                providerAuthenticated: true,
                providerCapabilities: provider.capabilities,
                errorMessage: nil
            )
        } catch {
            guard isCurrentRefresh(generation) else { return }
            let message = Self.describe(error)
            lastError = message
            let preservedRequest = preservedReviewRequestForError(local: local, remote: remote)
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: remote,
                reviewRequest: preservedRequest,
                providerAvailable: true,
                providerAuthenticated: true,
                providerCapabilities: provider.capabilities,
                errorMessage: message
            )
        }
    }

    func createReviewRequest(
        snapshot: ReviewLoopSnapshot,
        title: String,
        body: String,
        isDraft: Bool
    ) async throws -> URL {
        try await createReviewRequest(
            snapshot: snapshot,
            branch: snapshot.local.branchName,
            headOwner: snapshot.local.headRemoteOwner,
            baseBranch: snapshot.local.baseBranch,
            title: title,
            body: body,
            isDraft: isDraft
        )
    }

    func createReviewRequest(
        snapshot: ReviewLoopSnapshot,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        title: String,
        body: String,
        isDraft: Bool
    ) async throws -> URL {
        guard let remote = snapshot.remote else {
            throw CodeHostProviderError.unsupportedProvider(snapshot.remote?.kind ?? .github)
        }
        return try await createReviewRequest(
            remote: remote, branch: branch, headOwner: headOwner, baseBranch: baseBranch,
            title: title, body: body, draft: isDraft
        )
    }

    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String
    ) async throws -> ReviewRequest? {
        guard let provider = providerRegistry.provider(for: remote.kind) else {
            throw CodeHostProviderError.unsupportedProvider(remote.kind)
        }
        return try await provider.currentReviewRequest(
            remote: remote, branch: branch, headOwner: headOwner,
            baseBranch: baseBranch, cwd: worktreePath
        )
    }

    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        title: String,
        body: String,
        draft: Bool
    ) async throws -> URL {
        guard let provider = providerRegistry.provider(for: remote.kind) else {
            throw CodeHostProviderError.unsupportedProvider(remote.kind)
        }
        return try await provider.createReviewRequest(
            remote: remote,
            branch: branch,
            headOwner: headOwner,
            baseBranch: baseBranch,
            title: title,
            body: body,
            isDraft: draft,
            cwd: worktreePath
        )
    }

    func rerunFailedChecks() async -> Bool {
        guard let snapshot else { return false }
        return await rerunFailedChecks(snapshot: snapshot)
    }

    func rerunFailedChecks(snapshot: ReviewLoopSnapshot) async -> Bool {
        guard
              let remote = snapshot.remote,
              let provider = providerRegistry.provider(for: remote.kind)
        else { return false }

        lastError = nil
        do {
            try await provider.rerunFailedChecks(
                remote: remote,
                branch: snapshot.local.branchName,
                headSHA: snapshot.local.headSHA,
                request: snapshot.reviewRequest,
                cwd: worktreePath
            )
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func merge(snapshot: ReviewLoopSnapshot) async -> ReviewMergeOutcome? {
        guard
            let remote = snapshot.remote,
            let provider = providerRegistry.provider(for: remote.kind)
        else { return nil }

        lastError = nil
        do {
            // Re-query the provider immediately before merging so a refresh
            // race (the generation guard can let the merge-triggered refresh
            // return without publishing) can't merge on stale checks,
            // mergeability, review state, or a closed PR. Build a fresh
            // snapshot from live provider data + the caller-verified local
            // state and re-run the full merge gate.
            guard let fresh = try await provider.currentReviewRequest(
                remote: remote,
                branch: snapshot.local.branchName,
                headOwner: snapshot.local.headRemoteOwner,
                baseBranch: snapshot.local.baseBranch,
                cwd: worktreePath
            ) else {
                lastError = "The review request could not be found."
                return nil
            }
            let checks = try await provider.checks(remote: remote, request: fresh, cwd: worktreePath)
            let freshSnapshot = ReviewLoopSnapshot(
                local: snapshot.local,
                remote: remote,
                reviewRequest: fresh.withChecks(checks),
                providerAvailable: true,
                providerAuthenticated: true,
                providerCapabilities: provider.capabilities,
                errorMessage: nil
            )
            guard ReviewReadinessModel.canMergeReviewRequest(snapshot: freshSnapshot),
                  let request = freshSnapshot.reviewRequest
            else {
                lastError = "Merge is no longer available — the review state changed."
                return nil
            }
            try await provider.mergeReviewRequest(
                request,
                method: .squash,
                deleteBranch: true,
                cwd: worktreePath
            )
            return request.isMergeQueueEnabled ? .queued : .merged
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    private func isCurrentRefresh(_ generation: Int) -> Bool {
        generation == refreshGeneration
    }

    private static func withHeadRemote(
        _ local: ReviewLoopLocalState,
        remotes: [GitRemote],
        baseRemote: CodeHostRemote
    ) -> ReviewLoopLocalState {
        guard let candidate = headRemoteCandidate(for: local, remotes: remotes),
              let headRemote = CodeHostRemoteDetector.detect(
                  from: [GitRemote(name: candidate.name, url: candidate.url)],
                  supportedKinds: [baseRemote.kind]
              ),
              headRemote.kind == baseRemote.kind,
              headRemote.host == baseRemote.host
        else { return local }

        return ReviewLoopLocalState(
            branchName: local.branchName,
            headSHA: local.headSHA,
            baseBranch: local.baseBranch,
            hasWorkingTreeChanges: local.hasWorkingTreeChanges,
            hasStagedChanges: local.hasStagedChanges,
            aheadCommitCount: local.aheadCommitCount,
            hasUpstream: local.hasUpstream,
            upstreamRemoteName: local.upstreamRemoteName,
            upstreamBranchName: local.upstreamBranchName,
            headRemoteName: candidate.name,
            headRemoteOwner: headRemote.owner,
            upstreamAheadCommitCount: local.upstreamAheadCommitCount,
            needsPush: local.needsPush
        )
    }

    private static func headRemoteCandidate(for local: ReviewLoopLocalState, remotes: [GitRemote]) -> GitRemote? {
        if let upstreamRemoteName = local.upstreamRemoteName {
            return remotes.first { $0.name == upstreamRemoteName && $0.direction == .push }
                ?? remotes.first { $0.name == upstreamRemoteName && $0.direction == .fetch }
        }
        guard !local.hasUpstream else { return nil }

        return remotes.first { $0.name == "origin" && $0.direction == .push }
            ?? remotes.first { $0.name == "origin" && $0.direction == .fetch }
            ?? remotes.first { $0.direction == .push }
            ?? remotes.first { $0.direction == .fetch }
    }

    private func preservedReviewRequestForError(
        local: ReviewLoopLocalState,
        remote: CodeHostRemote
    ) -> ReviewRequest? {
        guard let snapshot,
              snapshot.local.branchName == local.branchName,
              Self.sameRepository(snapshot.remote, remote)
        else {
            return nil
        }
        return snapshot.reviewRequest
    }

    private static func sameRepository(_ lhs: CodeHostRemote?, _ rhs: CodeHostRemote) -> Bool {
        guard let lhs else { return false }
        return lhs.kind == rhs.kind
            && lhs.host == rhs.host
            && lhs.owner == rhs.owner
            && lhs.repository == rhs.repository
    }

    private static func describe(_ error: Error) -> String {
        let description = (error as NSError).localizedDescription
        if !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

#if DEBUG
extension ReviewLoopState {
    func setSnapshotForTests(_ snapshot: ReviewLoopSnapshot) {
        self.snapshot = snapshot
    }

    func updateLocalBranchForTests(_ branchName: String) {
        if let current = snapshot?.local {
            snapshot = ReviewLoopSnapshot(
                local: ReviewLoopLocalState(
                    branchName: branchName,
                    headSHA: current.headSHA,
                    baseBranch: current.baseBranch,
                    hasWorkingTreeChanges: current.hasWorkingTreeChanges,
                    hasStagedChanges: current.hasStagedChanges,
                    aheadCommitCount: current.aheadCommitCount,
                    hasUpstream: current.hasUpstream,
                    upstreamRemoteName: current.upstreamRemoteName,
                    upstreamBranchName: current.upstreamBranchName,
                    needsPush: current.needsPush
                ),
                remote: snapshot?.remote,
                reviewRequest: snapshot?.reviewRequest,
                providerAvailable: snapshot?.providerAvailable ?? false,
                providerAuthenticated: snapshot?.providerAuthenticated ?? false,
                providerCapabilities: snapshot?.providerCapabilities ?? .readOnly,
                errorMessage: snapshot?.errorMessage
            )
        }
    }

    func refreshForTests(local: ReviewLoopLocalState) async {
        await refresh(local: local, remotes: [])
    }
}
#endif
