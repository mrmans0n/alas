import Foundation
import Observation

@Observable
@MainActor
final class CommitPublishAmendProbeLoader {
    private var key: String?
    private var generation = 0
    private var state: CommitPublishAmendProbe = .loading

    func result(for key: String) -> CommitPublishAmendProbe {
        self.key == key ? state : .loading
    }

    func load(key: String, operation: () async throws -> HeadPublicationState) async {
        generation += 1
        let requestGeneration = generation
        self.key = key
        state = .loading
        let result: CommitPublishAmendProbe
        do {
            result = .init(try await operation())
        } catch {
            result = .failed(error.localizedDescription)
        }
        guard !Task.isCancelled, generation == requestGeneration else { return }
        state = result
    }
}

enum CommitPublishAmendProbe: Equatable, Sendable {
    case loading
    case notPublished
    case published
    case failed(String)

    init(_ state: HeadPublicationState) {
        self = state == .published ? .published : .notPublished
    }

    var disabledReason: String? {
        switch self {
        case .loading: "Checking whether HEAD is published."
        case .notPublished: nil
        case .published: "This commit is already published. Commit locally or turn off Amend before publishing."
        case .failed(let message): message
        }
    }
}

struct CommitPublishAvailability: Equatable, Sendable {
    let label: String
    let detail: String
    let disabledReason: String?
    let showsDraftToggle: Bool

    var isEnabled: Bool { disabledReason == nil }

    static func review(
        snapshot: ReviewLoopSnapshot?,
        supportedRemote: CodeHostRemote? = nil,
        isRefreshing: Bool = false,
        currentBranch: String? = nil,
        currentBaseBranch: String? = nil,
        lastError: String? = nil,
        mutationDisabledReason: String? = nil,
        amend: Bool = false,
        amendProbe: CommitPublishAmendProbe = .loading
    ) -> Self? {
        guard let remote = snapshot == nil ? supportedRemote : snapshot?.remote else { return nil }
        let hasRequest = snapshot?.reviewRequest != nil
        let label = hasRequest ? "Commit & push" : "Commit & \(remote.kind.reviewRequestLabel)"
        let detail = hasRequest ? "Push to \(remote.repositorySlug)" : "Create \(remote.kind.reviewRequestLabel) in \(remote.repositorySlug)"
        let reason: String?
        if let mutationDisabledReason {
            reason = mutationDisabledReason
        } else if let lastError {
            reason = lastError
        } else if isRefreshing || snapshot == nil {
            reason = "Wait for review state to load."
        } else if let snapshot {
            reason = reviewDisabledReason(snapshot, currentBranch: currentBranch, currentBaseBranch: currentBaseBranch)
                ?? (amend ? amendProbe.disabledReason : nil)
        } else {
            reason = "Wait for review state to load."
        }
        return Self(label: label, detail: detail, disabledReason: reason, showsDraftToggle: !hasRequest)
    }

    private static func reviewDisabledReason(
        _ snapshot: ReviewLoopSnapshot, currentBranch: String?, currentBaseBranch: String?
    ) -> String? {
        if let error = snapshot.errorMessage { return error }
        guard let remote = snapshot.remote else { return "No supported review host." }
        if !snapshot.providerAvailable { return "\(remote.kind.displayName) CLI missing." }
        if !snapshot.providerAuthenticated { return "\(remote.kind.displayName) authentication required." }
        if let currentBranch, currentBranch != snapshot.local.branchName {
            return "Refresh review state for the current branch."
        }
        if let currentBaseBranch, currentBaseBranch != snapshot.local.baseBranch {
            return "Refresh review state for the selected base."
        }
        let branch = currentBranch ?? snapshot.local.branchName
        let base = currentBaseBranch ?? snapshot.local.baseBranch
        let remotePrefix = "\(remote.remoteName)/"
        let normalizedBase = base.hasPrefix(remotePrefix) ? String(base.dropFirst(remotePrefix.count)) : base
        if branch.isEmpty || branch == "HEAD" { return "Checkout a branch before publishing." }
        if branch == normalizedBase { return "Checkout a feature branch before publishing." }
        if snapshot.local.pushState == .stale || snapshot.local.pushState == .diverged {
            return "Remote has commits not in this branch. Pull or rebase before publishing."
        }
        if snapshot.reviewRequest == nil && !snapshot.providerCapabilities.canCreateReviewRequest {
            return "Creating a \(remote.kind.reviewRequestLabel) is unavailable."
        }
        return nil
    }
}

enum DraftCommitPreferredAction: String, Codable, Equatable, Sendable {
    case commit
    case publish
}

enum CommitPublishPhase: String, Codable, Equatable, Sendable {
    case push
    case createReviewRequest
    case sync

    func retryLabel(reviewRequestLabel: String) -> String {
        switch self {
        case .push: "Retry push"
        case .createReviewRequest: "Retry create \(reviewRequestLabel)"
        case .sync: "Retry sync"
        }
    }
}

struct CommitPublishReviewTarget: Codable, Equatable, Sendable {
    let provider: CodeHostKind
    let host: String
    let owner: String
    let repository: String
    let repositorySlug: String
    let remoteName: String
    let webURL: URL
    let branch: String
    let upstreamBranch: String?
    let headOwner: String?
    let baseBranch: String
    let reviewRequestExisted: Bool
    let createAsDraft: Bool
    var pushURL: String? = nil
    var pushRemoteName: String? = nil

    var remote: CodeHostRemote {
        CodeHostRemote(
            kind: provider,
            host: host,
            owner: owner,
            repository: repository,
            remoteName: remoteName,
            webURL: webURL
        )
    }

    @MainActor
    static func capture(
        snapshot: ReviewLoopSnapshot,
        createAsDraft: Bool,
        runGit: ([String]) async throws -> ProcessResult
    ) async throws -> Self {
        guard let remote = snapshot.remote else {
            throw CommitPublishWorkflowError.invalidDestination(phase: .push)
        }
        let local = snapshot.local
        let pushRemote = local.upstreamRemoteName ?? local.headRemoteName ?? remote.remoteName
        let result = try await runGit(["remote", "get-url", "--push", pushRemote])
        try GitService.assertSuccess(result, op: "Resolve push destination")
        let pushURL = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pushURL.isEmpty else { throw CommitPublishWorkflowError.missingPushDestination }
        return Self(
            provider: remote.kind, host: remote.host, owner: remote.owner, repository: remote.repository,
            repositorySlug: remote.repositorySlug, remoteName: remote.remoteName, webURL: remote.webURL,
            branch: local.branchName, upstreamBranch: local.upstreamBranchName,
            headOwner: local.headRemoteOwner, baseBranch: local.baseBranch,
            reviewRequestExisted: snapshot.reviewRequest != nil, createAsDraft: createAsDraft,
            pushURL: pushURL, pushRemoteName: pushRemote
        )
    }
}

enum CommitPublishDestination: Codable, Equatable, Sendable {
    case review(CommitPublishReviewTarget)
    case gg
}

struct CommitPublishCheckpoint: Codable, Equatable, Sendable {
    let commitSHA: String
    let baseRef: String
    let commitTitle: String
    let subject: String
    let body: String
    let destination: CommitPublishDestination
    var nextPhase: CommitPublishPhase
}
