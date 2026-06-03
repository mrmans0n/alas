import Foundation

struct ReviewReadinessModel: Equatable, Sendable {
    struct Chip: Equatable, Sendable, Identifiable {
        enum Tone: String, Codable, Equatable, Sendable {
            case accent
            case success
            case warning
            case danger
            case muted
        }

        let id: String
        let title: String
        let tone: Tone

        init(id: String, title: String, tone: Tone = .muted) {
            self.id = id
            self.title = title
            self.tone = tone
        }
    }

    struct Fact: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let value: String
    }

    struct Action: Equatable, Sendable, Identifiable {
        enum Emphasis: String, Codable, Equatable, Sendable {
            case primary
            case normal
        }

        let kind: ReviewReadinessActionKind
        let title: String
        let isEnabled: Bool

        var id: ReviewReadinessActionKind { kind }

        var iconName: String {
            switch kind {
            case .refresh: "arrow.clockwise"
            case .pushBranch: "arrow.up"
            case .forcePushBranch: "exclamationmark.arrow.triangle.2.circlepath"
            case .createReviewRequest: "plus"
            case .openReviewRequest: "arrow.up.right.square"
            case .rerunFailedChecks: "arrow.clockwise"
            case .openAgentHandoff: "sparkle"
            case .merge: "arrow.triangle.merge"
            }
        }

        var emphasis: Emphasis {
            switch kind {
            case .pushBranch, .forcePushBranch, .createReviewRequest, .openAgentHandoff:
                .primary
            case .refresh, .openReviewRequest, .rerunFailedChecks, .merge:
                .normal
            }
        }
    }

    let identity: String
    let title: String?
    let chips: [Chip]
    let facts: [Fact]
    let actions: [Action]
    let blockingText: String?

    init(snapshot: ReviewLoopSnapshot?, lastError: String?, canOpenAgentHandoff: Bool) {
        guard let snapshot else {
            identity = "Review readiness"
            title = nil
            chips = [Chip(id: "loading", title: "Checking", tone: .accent)]
            facts = []
            actions = [Action(kind: .refresh, title: "Refresh", isEnabled: true)]
            blockingText = lastError ?? "Review state is still loading."
            return
        }

        let request = snapshot.reviewRequest
        let remote = snapshot.remote
        let kind = request?.provider ?? remote?.kind
        let requestLabel = kind?.reviewRequestLabel ?? "review request"

        identity = request?.displayIdentity ?? kind?.displayName ?? "Review readiness"
        title = request?.title
        blockingText = lastError ?? snapshot.errorMessage ?? Self.providerBlockingText(snapshot) ?? Self.localBlockingText(snapshot)

        facts = Self.makeFacts(snapshot: snapshot, requestLabel: requestLabel)
        if lastError != nil || snapshot.errorMessage != nil {
            chips = [Chip(id: "error", title: "Needs attention", tone: .warning)]
            actions = [Action(kind: .refresh, title: "Refresh", isEnabled: true)]
            return
        }

        chips = Self.makeChips(snapshot: snapshot, requestLabel: requestLabel)
        actions = Self.makeActions(
            snapshot: snapshot,
            requestLabel: requestLabel,
            canOpenAgentHandoff: canOpenAgentHandoff
        )
    }

    private static func providerBlockingText(_ snapshot: ReviewLoopSnapshot) -> String? {
        guard let remote = snapshot.remote else { return "No supported review host" }
        if !snapshot.providerAvailable { return "\(remote.kind.displayName) CLI missing" }
        if !snapshot.providerAuthenticated { return "\(remote.kind.displayName) auth needed" }
        return nil
    }

    private static func localBlockingText(_ snapshot: ReviewLoopSnapshot) -> String? {
        switch snapshot.local.pushState {
        case .diverged:
            "Remote has commits not in this branch. Force push uses --force-with-lease."
        case .inSync, .missingUpstream, .unpushed:
            nil
        }
    }

    private static func makeFacts(snapshot: ReviewLoopSnapshot, requestLabel: String) -> [Fact] {
        let remoteValue = snapshot.remote.map { "\($0.kind.displayName) \($0.repositorySlug)" } ?? "Unsupported"
        let requestValue = snapshot.reviewRequest?.displayIdentity ?? "No \(requestLabel)"
        let checksValue = snapshot.reviewRequest?.worstCheckBucket.map(Self.checkText) ?? "none"
        let reviewValue = snapshot.reviewRequest.map { reviewText($0.reviewDecision) } ?? "none"
        let mergeValue = snapshot.reviewRequest.map { mergeText($0.mergeState) } ?? "none"

        return [
            Fact(id: "branch", label: "Branch", value: snapshot.local.branchName),
            Fact(id: "remote", label: "Remote", value: remoteValue),
            Fact(id: "request", label: "Review request", value: requestValue),
            Fact(id: "checks", label: "Checks", value: checksValue),
            Fact(id: "review", label: "Review", value: reviewValue),
            Fact(id: "merge", label: "Merge", value: mergeValue),
        ]
    }

    private static func makeChips(snapshot: ReviewLoopSnapshot, requestLabel: String) -> [Chip] {
        guard snapshot.remote != nil else {
            return [Chip(id: "unsupported", title: "No supported review host", tone: .muted)]
        }
        if !snapshot.providerAvailable {
            return [Chip(id: "cli-missing", title: "CLI missing", tone: .warning)]
        }
        if !snapshot.providerAuthenticated {
            return [Chip(id: "auth-needed", title: "Auth needed", tone: .warning)]
        }
        if snapshot.local.pushState == .diverged {
            return [Chip(id: "remote-diverged", title: "Remote diverged", tone: .warning)]
        }
        if snapshot.local.needsPush {
            return [Chip(id: "unpushed", title: "Unpushed", tone: .accent)]
        }
        guard let request = snapshot.reviewRequest else {
            return [Chip(id: "no-request", title: "No \(requestLabel)", tone: .muted)]
        }
        if request.worstCheckBucket == .fail {
            return [Chip(id: "checks-failed", title: "CI failed", tone: .danger)]
        }
        if request.worstCheckBucket == .pending {
            return [Chip(id: "checks-pending", title: "Checks running", tone: .accent)]
        }
        if request.hasActionableFeedback {
            return [Chip(id: "review-feedback", title: "Review feedback", tone: .warning)]
        }
        if request.reviewDecision == .reviewRequired {
            return [Chip(id: "review-pending", title: "Review pending", tone: .muted)]
        }
        if request.reviewDecision == .approved, request.mergeState == .clean {
            return [Chip(id: "ready", title: "Ready", tone: .success)]
        }
        return [Chip(id: "attention", title: "Needs attention", tone: .warning)]
    }

    private static func makeActions(
        snapshot: ReviewLoopSnapshot,
        requestLabel: String,
        canOpenAgentHandoff: Bool
    ) -> [Action] {
        var actions: [Action] = [Action(kind: .refresh, title: "Refresh", isEnabled: true)]
        guard snapshot.remote != nil, snapshot.providerAvailable, snapshot.providerAuthenticated else {
            return actions
        }
        if snapshot.local.pushState == .diverged {
            actions.append(Action(kind: .forcePushBranch, title: "Force push", isEnabled: true))
        } else if snapshot.local.needsPush {
            actions.append(Action(kind: .pushBranch, title: "Push", isEnabled: true))
        } else if let request = snapshot.reviewRequest {
            if snapshot.providerCapabilities.canOpenReviewRequest {
                actions.append(Action(kind: .openReviewRequest, title: request.provider.openReviewRequestTitle, isEnabled: true))
            }
            if request.worstCheckBucket == .fail, snapshot.providerCapabilities.canRerunFailedChecks {
                actions.append(Action(kind: .rerunFailedChecks, title: "Rerun", isEnabled: true))
            }
            if (request.worstCheckBucket == .fail || request.hasActionableFeedback), canOpenAgentHandoff {
                actions.append(Action(kind: .openAgentHandoff, title: "Open in Agent", isEnabled: true))
            }
        } else if snapshot.providerCapabilities.canCreateReviewRequest {
            actions.append(Action(kind: .createReviewRequest, title: "Create \(requestLabel)", isEnabled: true))
        }
        return actions
    }

    private static func checkText(_ bucket: ReviewCheckBucket) -> String {
        switch bucket {
        case .pass: "passing"
        case .fail: "failed"
        case .pending: "running"
        case .skipping: "skipped"
        case .cancel: "cancelled"
        case .unknown: "unknown"
        }
    }

    private static func reviewText(_ decision: ReviewDecision) -> String {
        switch decision {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .reviewRequired: "required"
        case .unknown: "unknown"
        }
    }

    private static func mergeText(_ state: ReviewMergeState) -> String {
        switch state {
        case .clean: "clean"
        case .blocked: "blocked"
        case .dirty: "dirty"
        case .unstable: "unstable"
        case .unknown: "unknown"
        }
    }
}

enum ReviewReadinessActionKind: String, Codable, Equatable, Sendable {
    case refresh
    case pushBranch
    case forcePushBranch
    case createReviewRequest
    case openReviewRequest
    case rerunFailedChecks
    case openAgentHandoff
    case merge
}
