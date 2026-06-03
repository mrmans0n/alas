import Foundation
import Observation

struct ReviewLoopRefreshAttempt: Equatable, Sendable {
    let local: ReviewLoopLocalState?
    fileprivate let generation: Int
}

@Observable
@MainActor
final class ReviewLoopState {
    private let worktreePath: URL
    private var baseBranch: String
    private let providerRegistry: CodeHostProviderRegistry
    private var refreshGeneration: Int = 0

    private(set) var snapshot: ReviewLoopSnapshot?
    private(set) var isRefreshing: Bool = false
    private(set) var isExpanded: Bool = false
    private(set) var lastError: String?

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

    func updateBaseBranch(_ branch: String) {
        baseBranch = branch
        if let current = snapshot?.local {
            let local = ReviewLoopLocalState(
                branchName: current.branchName,
                headSHA: current.headSHA,
                baseBranch: branch,
                hasWorkingTreeChanges: current.hasWorkingTreeChanges,
                hasStagedChanges: current.hasStagedChanges,
                aheadCommitCount: current.aheadCommitCount,
                hasUpstream: current.hasUpstream,
                upstreamRemoteName: current.upstreamRemoteName,
                headRemoteOwner: current.headRemoteOwner,
                upstreamAheadCommitCount: current.upstreamAheadCommitCount,
                needsPush: current.needsPush
            )
            snapshot = ReviewLoopSnapshot(
                local: local,
                remote: snapshot?.remote,
                reviewRequest: snapshot?.reviewRequest,
                providerAvailable: snapshot?.providerAvailable ?? false,
                providerAuthenticated: snapshot?.providerAuthenticated ?? false,
                providerCapabilities: snapshot?.providerCapabilities ?? .readOnly,
                errorMessage: snapshot?.errorMessage
            )
        }
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

        let supportedKinds = providerRegistry.supportedKinds
        let preferredRemoteName = Self.preferredRemoteName(for: baseLocal.baseBranch, remotes: remotes)
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
        let local = Self.withHeadRemoteOwner(baseLocal, remotes: remotes, baseRemote: remote)

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

        let providerAvailable = await provider.isAvailable()
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
                cwd: worktreePath
            )
            guard isCurrentRefresh(generation) else { return }
            let loadedRequest: ReviewRequest?
            if let request {
                let checks = try await provider.checks(remote: remote, request: request, cwd: worktreePath)
                guard isCurrentRefresh(generation) else { return }
                loadedRequest = ReviewRequest(
                    remote: request.remote,
                    number: request.number,
                    title: request.title,
                    url: request.url,
                    state: request.state,
                    isDraft: request.isDraft,
                    headRefName: request.headRefName,
                    baseRefName: request.baseRefName,
                    reviewDecision: request.reviewDecision,
                    mergeState: request.mergeState,
                    checks: checks,
                    threads: request.threads
                )
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

    func createReviewRequest() async -> Bool {
        guard let snapshot else { return false }
        return await createReviewRequest(snapshot: snapshot)
    }

    func createReviewRequest(snapshot: ReviewLoopSnapshot) async -> Bool {
        guard
              let remote = snapshot.remote,
              let provider = providerRegistry.provider(for: remote.kind)
        else { return false }

        lastError = nil
        do {
            _ = try await provider.createReviewRequest(
                remote: remote,
                branch: snapshot.local.branchName,
                headOwner: snapshot.local.headRemoteOwner,
                baseBranch: snapshot.local.baseBranch,
                title: snapshot.local.branchName,
                body: "Created from Alas.",
                cwd: worktreePath
            )
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
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
                cwd: worktreePath
            )
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    private func isCurrentRefresh(_ generation: Int) -> Bool {
        generation == refreshGeneration
    }

    private static func preferredRemoteName(for baseBranch: String, remotes: [GitRemote]) -> String? {
        remotes.first { baseBranch.hasPrefix("\($0.name)/") }?.name
    }

    private static func withHeadRemoteOwner(
        _ local: ReviewLoopLocalState,
        remotes: [GitRemote],
        baseRemote: CodeHostRemote
    ) -> ReviewLoopLocalState {
        guard let upstreamRemoteName = local.upstreamRemoteName,
              let upstreamRemote = remotes.first(where: { $0.name == upstreamRemoteName }),
              let headRemote = CodeHostRemoteDetector.detect(
                  from: [upstreamRemote],
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
            headRemoteOwner: headRemote.owner,
            upstreamAheadCommitCount: local.upstreamAheadCommitCount,
            needsPush: local.needsPush
        )
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
