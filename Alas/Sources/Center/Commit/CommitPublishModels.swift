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
    var reviewRequestLabel: String = "PR"

    var isEnabled: Bool { disabledReason == nil }

    static func gg(disabledReason: String? = nil) -> Self {
        Self(label: "Commit & sync", detail: "Sync stack", disabledReason: disabledReason, showsDraftToggle: false)
    }

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
        return Self(label: label, detail: detail, disabledReason: reason, showsDraftToggle: !hasRequest,
            reviewRequestLabel: remote.kind.reviewRequestLabel)
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

struct CommitPublishPresentation: Sendable {
    struct Action: Equatable, Sendable {
        let label: String
        let disabledReason: String?
        let detail: String

        var isEnabled: Bool { disabledReason == nil }
        var help: String { disabledReason ?? detail }
    }

    let commit: Action
    let publish: Action?
    let preferredActionPosition: CommitComposerActionPosition
    let activityText: String?
    let draftToggleLabel: String?
    let draftToggleHelp: String
    let draftToggleEnabled: Bool
    let editorDisabled: Bool
    let mutationsDisabled: Bool

    init(
        subject: String,
        hasStaged: Bool,
        amend: Bool = false,
        busy: Bool = false,
        activity: CommitPublishActivity = .idle,
        checkpoint: CommitPublishCheckpoint? = nil,
        preferredAction: DraftCommitPreferredAction = .commit,
        availability: CommitPublishAvailability? = nil
    ) {
        let reviewRequestLabel: String
        if let checkpoint, case .review(let target) = checkpoint.destination {
            reviewRequestLabel = target.provider.reviewRequestLabel
        } else {
            reviewRequestLabel = availability?.reviewRequestLabel ?? "PR"
        }
        let isBusy = busy || activity != .idle
        activityText = activity.actionLabel(reviewRequestLabel: reviewRequestLabel)
        editorDisabled = checkpoint != nil
        mutationsDisabled = isBusy || editorDisabled
        let initialDisabledReason: String?
        if !hasStaged {
            initialDisabledReason = "Stage changes before committing."
        } else if subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            initialDisabledReason = "Enter a commit subject."
        } else {
            initialDisabledReason = nil
        }
        let busyReason = isBusy ? "Another operation is running." : nil
        commit = Action(
            label: activity == .committing ? "Committing..." : amend ? "Amend" : "Commit",
            disabledReason: busyReason ?? (checkpoint != nil ? "Finish publishing this commit first." : initialDisabledReason),
            detail: amend ? "Amend the local commit." : "Commit staged changes locally."
        )
        if let checkpoint {
            let label = checkpoint.nextPhase.retryLabel(reviewRequestLabel: reviewRequestLabel)
            publish = Action(label: activityText ?? label, disabledReason: busyReason, detail: label)
        } else if let availability {
            publish = Action(label: activityText ?? availability.label,
                disabledReason: busyReason ?? availability.disabledReason ?? initialDisabledReason,
                detail: availability.detail)
        } else {
            publish = nil
        }
        preferredActionPosition = publish != nil && (checkpoint != nil || preferredAction == .publish) ? .trailing : .leading
        draftToggleLabel = availability?.showsDraftToggle == true ? "Draft \(reviewRequestLabel)" : nil
        draftToggleHelp = "Create the \(reviewRequestLabel) as a draft."
        draftToggleEnabled = draftToggleLabel != nil && !mutationsDisabled
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
    var expectedHeadSHA: String? = nil
    let upstreamBranch: String?
    let headOwner: String?
    let baseBranch: String
    let reviewRequestExisted: Bool
    let createAsDraft: Bool
    var pushURL: String? = nil
    var pushURLs: [String]? = nil
    var pushRemoteName: String? = nil

    var capturedPushURLs: [String] { pushURLs ?? pushURL.map { [$0] } ?? [] }

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
        let pushRemote: String
        if let upstreamRemoteName = local.upstreamRemoteName {
            guard local.headRemoteName == upstreamRemoteName else {
                throw CommitPublishWorkflowError.incompatiblePushRemote
            }
            pushRemote = upstreamRemoteName
        } else {
            pushRemote = local.headRemoteName ?? remote.remoteName
        }
        let branchResult = try await runGit(["symbolic-ref", "--short", "HEAD"])
        try GitService.assertSuccess(branchResult, op: "Resolve current branch")
        let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == local.branchName else {
            throw CommitPublishWorkflowError.branchMismatch(expected: local.branchName, actual: branch)
        }
        let headResult = try await runGit(["rev-parse", "--verify", "HEAD"])
        try GitService.assertSuccess(headResult, op: "Resolve HEAD")
        let headSHA = headResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard headSHA == local.headSHA else {
            throw CommitPublishWorkflowError.headMismatch(expected: local.headSHA, actual: headSHA)
        }
        let result = try await runGit(["remote", "get-url", "--push", "--all", pushRemote])
        try GitService.assertSuccess(result, op: "Resolve push destination")
        let pushURLs = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard let pushURL = pushURLs.first, !pushURL.isEmpty else { throw CommitPublishWorkflowError.missingPushDestination }
        return Self(
            provider: remote.kind, host: remote.host, owner: remote.owner, repository: remote.repository,
            repositorySlug: remote.repositorySlug, remoteName: remote.remoteName, webURL: remote.webURL,
            branch: branch, expectedHeadSHA: headSHA, upstreamBranch: local.upstreamBranchName,
            headOwner: local.headRemoteOwner, baseBranch: local.baseBranch,
            reviewRequestExisted: snapshot.reviewRequest != nil, createAsDraft: createAsDraft,
            pushURL: pushURL, pushURLs: pushURLs, pushRemoteName: pushRemote
        )
    }
}

enum CommitPublishDestination: Codable, Equatable, Sendable {
    case review(CommitPublishReviewTarget)
    case gg(GGStackTargetIdentity? = nil)

    private enum CodingKeys: String, CodingKey {
        case review, gg
    }

    private enum AssociatedValueKeys: String, CodingKey {
        case value = "_0"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.review) {
            let review = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .review)
            self = .review(try review.decode(CommitPublishReviewTarget.self, forKey: .value))
        } else if container.contains(.gg) {
            let gg = try container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .gg)
            self = .gg(try gg.decodeIfPresent(GGStackTargetIdentity.self, forKey: .value))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .review, in: container, debugDescription: "Unknown publish destination.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .review(let target):
            var review = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .review)
            try review.encode(target, forKey: .value)
        case .gg(let target):
            var gg = container.nestedContainer(keyedBy: AssociatedValueKeys.self, forKey: .gg)
            try gg.encodeIfPresent(target, forKey: .value)
        }
    }
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
