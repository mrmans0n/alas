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
        let isInFlight: Bool
        let emphasis: Emphasis

        init(
            kind: ReviewReadinessActionKind,
            title: String,
            isEnabled: Bool,
            isInFlight: Bool = false,
            emphasis: Emphasis? = nil
        ) {
            self.kind = kind
            self.title = title
            self.isEnabled = isEnabled
            self.isInFlight = isInFlight
            self.emphasis = emphasis ?? Self.defaultEmphasis(for: kind)
        }

        var id: ReviewReadinessActionKind { kind }

        var iconName: String {
            switch kind {
            case .refresh: "arrow.clockwise"
            case .pushBranch: "arrow.up"
            case .forcePushBranch: "exclamationmark.arrow.triangle.2.circlepath"
            case .createReviewRequest: "plus"
            case .openReviewRequest: "arrow.up.right.square"
            case .rerunFailedChecks: "arrow.clockwise"
            case .inspectReviewEvidence: "doc.text.magnifyingglass"
            case .openAgentHandoff: "sparkle"
            case .merge: "arrow.triangle.merge"
            }
        }

        static func defaultEmphasis(for kind: ReviewReadinessActionKind) -> Emphasis {
            switch kind {
            case .pushBranch, .forcePushBranch, .createReviewRequest, .inspectReviewEvidence, .merge:
                .primary
            case .refresh, .openReviewRequest, .rerunFailedChecks, .openAgentHandoff:
                .normal
            }
        }
    }

    let identity: String
    let providerIconName: String
    let providerTitle: String?
    let requestNumberTitle: String?
    let title: String?
    let chips: [Chip]
    let facts: [Fact]
    let actions: [Action]
    let blockingText: String?

    init(
        snapshot: ReviewLoopSnapshot?,
        lastError: String?,
        canOpenAgentHandoff: Bool,
        inFlightAction: ReviewReadinessActionKind? = nil
    ) {
        guard let snapshot else {
            identity = "Review readiness"
            providerIconName = "branch"
            providerTitle = nil
            requestNumberTitle = nil
            title = nil
            chips = [Chip(id: "loading", title: "Checking", tone: .accent)]
            facts = []
            actions = Self.actions(
                [Action(kind: .refresh, title: "Refresh", isEnabled: true)],
                applying: inFlightAction
            )
            blockingText = lastError ?? "Review state is still loading."
            return
        }

        let request = snapshot.reviewRequest
        let remote = snapshot.remote
        let kind = request?.provider ?? remote?.kind
        let requestLabel = kind?.reviewRequestLabel ?? "review request"

        identity = request?.displayIdentity ?? kind?.displayName ?? "Review readiness"
        providerIconName = kind?.iconName ?? "branch"
        providerTitle = kind?.displayName
        requestNumberTitle = request.map { "\($0.provider.reviewRequestNumberPrefix)\($0.number)" }
        title = request?.title
        blockingText = lastError ?? snapshot.errorMessage ?? Self.providerBlockingText(snapshot) ?? Self.localBlockingText(snapshot)

        facts = Self.makeFacts(snapshot: snapshot, requestLabel: requestLabel)
        if lastError != nil || snapshot.errorMessage != nil {
            chips = [Chip(id: "error", title: "Needs attention", tone: .warning)]
            actions = Self.actions(
                [Action(kind: .refresh, title: "Refresh", isEnabled: true)],
                applying: inFlightAction
            )
            return
        }

        chips = Self.makeChips(snapshot: snapshot, requestLabel: requestLabel)
        actions = Self.actions(
            Self.makeActions(
                snapshot: snapshot,
                requestLabel: requestLabel,
                canOpenAgentHandoff: canOpenAgentHandoff
            ),
            applying: inFlightAction
        )
    }

    private static func actions(
        _ actions: [Action],
        applying inFlightAction: ReviewReadinessActionKind?
    ) -> [Action] {
        guard let inFlightAction else { return actions }
        return actions.map { action in
            Action(
                kind: action.kind,
                title: action.title,
                isEnabled: false,
                isInFlight: action.kind == inFlightAction,
                emphasis: action.emphasis
            )
        }
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
            "Remote has commits not in this branch. Pull, rebase, or force push from the terminal if intentional."
        case .stale:
            "Remote has commits not in this branch. Pull or rebase before using review actions."
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
        if snapshot.local.pushState == .stale {
            return [Chip(id: "remote-stale", title: "Remote ahead", tone: .warning)]
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
        let refreshAction = Action(kind: .refresh, title: "Refresh", isEnabled: true)
        var actions: [Action] = []
        guard snapshot.remote != nil, snapshot.providerAvailable, snapshot.providerAuthenticated else {
            return [refreshAction]
        }
        if snapshot.local.pushState == .diverged || snapshot.local.pushState == .stale {
            return [refreshAction]
        } else if snapshot.local.needsPush {
            actions.append(Action(kind: .pushBranch, title: "Push", isEnabled: true))
        } else if let request = snapshot.reviewRequest {
            if request.worstCheckBucket == .pending {
                actions.append(refreshAction)
            }
            let canMergeNow = Self.canMergeReviewRequest(snapshot: snapshot)
            if canMergeNow {
                actions.append(Action(kind: .merge, title: request.provider.mergeReviewRequestTitle, isEnabled: true))
            }
            if snapshot.providerCapabilities.canOpenReviewRequest {
                actions.append(Action(kind: .openReviewRequest, title: request.provider.openReviewRequestTitle, isEnabled: true))
            }
            if request.hasRerunnableFailedCheck, snapshot.providerCapabilities.canRerunFailedChecks {
                actions.append(Action(kind: .rerunFailedChecks, title: "Rerun", isEnabled: true))
            }
            if canMergeNow {
                actions.append(Action(kind: .inspectReviewEvidence, title: "Review diff", isEnabled: true, emphasis: .normal))
            } else if request.worstCheckBucket == .fail || request.hasActionableFeedback {
                actions.append(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true))
            }
        } else if canCreateReviewRequest(snapshot) {
            actions.append(Action(kind: .createReviewRequest, title: "Create \(requestLabel)", isEnabled: true))
        }
        return actions.isEmpty ? [refreshAction] : actions
    }

    /// Single source of truth for "can this review request be merged now?".
    /// Includes the local-sync preconditions (`makeActions` enforces these
    /// structurally via its else-if chain, but the Inspect-tab button and the
    /// merge handler reuse this helper directly, so the guards must live here
    /// too): merging a green PR whose head predates unpushed local commits
    /// would drop that work and delete the branch.
    static func canMergeReviewRequest(snapshot: ReviewLoopSnapshot) -> Bool {
        guard let request = snapshot.reviewRequest else { return false }
        // A failed refresh preserves the previous (possibly green) request but
        // sets `errorMessage`; the checks/mergeability are then stale, so never
        // merge off an errored snapshot — mirror the drawer, which suppresses
        // all actions in this state.
        guard snapshot.errorMessage == nil else { return false }
        guard snapshot.remote != nil,
              snapshot.providerAvailable,
              snapshot.providerAuthenticated
        else { return false }
        guard snapshot.local.pushState != .diverged,
              snapshot.local.pushState != .stale,
              !snapshot.local.needsPush
        else { return false }
        // A dirty worktree means in-progress work on this branch that isn't in
        // any commit (so `needsPush`/`headSHA` still look clean). Merging and
        // deleting the branch now would strand it — block until it's committed
        // or cleared.
        guard !snapshot.local.hasWorkingTreeChanges,
              !snapshot.local.hasStagedChanges
        else { return false }
        // The local worktree HEAD must be exactly the reviewed PR head. If
        // another contributor pushed and this worktree hasn't fetched, the
        // provider reports the new remote head while local refs (and thus
        // needsPush/upstreamAhead) look clean off the stale local commit —
        // merging would ship/delete commits never present in the review diff.
        guard request.headSHA == snapshot.local.headSHA else { return false }
        return snapshot.providerCapabilities.canMerge
            && request.state == .open
            && !request.isDraft
            && request.mergeState == .clean
            && request.reviewDecision != .reviewRequired
            && request.areThreadsComplete
            && !request.hasActionableFeedback
            && (request.worstCheckBucket == nil || request.worstCheckBucket == .pass)
    }

    private static func canCreateReviewRequest(_ snapshot: ReviewLoopSnapshot) -> Bool {
        snapshot.providerCapabilities.canCreateReviewRequest
            && snapshot.local.aheadCommitCount > 0
            && !isLocalBranchSelectedBase(snapshot)
    }

    private static func isLocalBranchSelectedBase(_ snapshot: ReviewLoopSnapshot) -> Bool {
        snapshot.local.branchName == normalizedBranchName(
            snapshot.local.baseBranch,
            remoteName: snapshot.remote?.remoteName
        )
    }

    private static func normalizedBranchName(_ branchName: String, remoteName: String?) -> String {
        guard let remoteName else { return branchName }
        let prefix = "\(remoteName)/"
        guard branchName.hasPrefix(prefix) else { return branchName }
        return String(branchName.dropFirst(prefix.count))
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

private extension ReviewRequest {
    var hasRerunnableFailedCheck: Bool {
        checks.contains { $0.bucket == .fail && $0.workflow != nil }
    }
}

enum ReviewReadinessActionKind: String, Codable, Equatable, Sendable {
    case refresh
    case pushBranch
    case forcePushBranch
    case createReviewRequest
    case openReviewRequest
    case rerunFailedChecks
    case inspectReviewEvidence
    case openAgentHandoff
    case merge
}
