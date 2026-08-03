import Foundation

struct MissionLegPresentation: Equatable, Identifiable {
    let id: MissionLegID
    let ordinal: Int
    let projectID: String
    let state: MissionLegState
    let stateLabel: String
    let stateTone: MissionTabPresentation.StateTone
    let checkpointCopy: String?
    let errorCopy: String?
    let branchCopy: String
    let baseCopy: String
    let destinationCopy: String
    let agentCopy: String
    let diffCounts: MissionDiffCounts?
    let diffCopy: String
    let reviewCopy: String
    let reviewDestination: URL?
    let actions: MissionTabPresentation.Actions
    let agentDestination: String?
    let changesDestination: String?

    init(
        aggregate: MissionAggregate,
        leg: MissionLeg,
        worktree: Worktree?,
        acpSummary: MissionACPSummary? = nil,
        diffCounts: MissionDiffCounts? = nil,
        reviewSnapshot: ReviewLoopSnapshot? = nil,
        worktreeArchived: Bool = false,
        worktreeRecoveryAvailable: Bool = false,
        availableACPAgentIDs: Set<String> = []
    ) {
        id = leg.id
        ordinal = leg.ordinal
        projectID = leg.projectId
        state = leg.state
        stateLabel = Self.stateLabel(leg.state)
        stateTone = Self.stateTone(leg.state)
        checkpointCopy = Self.checkpointCopy(leg)
        errorCopy = leg.attentionReason
        branchCopy = worktree?.branch ?? leg.branch
        baseCopy = leg.baseRef
        destinationCopy = worktree?.path.path ?? leg.destinationPath
        if let acpSummary {
            agentCopy = "\(acpSummary.agentName) · \(acpSummary.activity.label)"
        } else {
            agentCopy = "\(leg.agentId) · Session unavailable"
        }
        self.diffCounts = diffCounts
        diffCopy = Self.diffCopy(diffCounts)
        reviewCopy = Self.reviewCopy(identity: leg.reviewIdentity, snapshot: reviewSnapshot)
        reviewDestination = leg.reviewIdentity?.url

        let isAttention = leg.state == .needsAttention
        let retryWorktree = isAttention && leg.setupCheckpoint == .creatingWorktree
        let retryAgent = isAttention && leg.setupCheckpoint == .startingAgent
        let hasUsableWorktree = worktree != nil && !worktreeArchived
        let openAgent = hasUsableWorktree
            && leg.acpSessionId != nil
            && leg.setupCheckpoint == .running
        let canComplete = [MissionState.running, .needsAttention, .readyToComplete]
            .contains(aggregate.mission.state)
        let canRecover = (worktreeArchived && worktree != nil)
            || (worktreeRecoveryAvailable
                && isAttention
                && leg.setupCheckpoint == .running
                && leg.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        actions = MissionTabPresentation.Actions(
            openAgent: openAgent,
            openChanges: hasUsableWorktree,
            openIssue: true,
            refresh: true,
            retryWorktree: retryWorktree,
            retryAgent: retryAgent,
            recoverWorktree: canRecover,
            completeMission: canComplete
        )
        agentDestination = leg.acpSessionId
        changesDestination = worktree?.id

        _ = availableACPAgentIDs
    }

    private static func stateLabel(_ state: MissionLegState) -> String {
        switch state {
        case .creating: "Creating"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .ready: "Ready"
        }
    }

    private static func stateTone(_ state: MissionLegState) -> MissionTabPresentation.StateTone {
        switch state {
        case .creating: .progress
        case .running: .success
        case .needsAttention: .attention
        case .ready: .warning
        }
    }

    private static func checkpointCopy(_ leg: MissionLeg) -> String? {
        switch (leg.state, leg.setupCheckpoint) {
        case (.creating, .creatingWorktree): "Creating worktree…"
        case (.creating, .startingAgent): "Starting ACP agent…"
        case (.creating, .running): "Finalizing Mission setup…"
        case (.needsAttention, .creatingWorktree): "Worktree creation needs attention."
        case (.needsAttention, .startingAgent): "ACP agent startup needs attention."
        case (.needsAttention, .running): "Mission leg needs attention."
        default: nil
        }
    }

    private static func diffCopy(_ diffCounts: MissionDiffCounts?) -> String {
        guard let diffCounts else { return "Changes unavailable" }
        let files = diffCounts.fileCount == 1 ? "1 file" : "\(diffCounts.fileCount) files"
        return "\(files) · +\(diffCounts.additions) −\(diffCounts.deletions)"
    }

    private static func reviewCopy(
        identity: MissionReviewIdentity?,
        snapshot: ReviewLoopSnapshot?
    ) -> String {
        guard let identity else { return "No \(CodeHostKind.github.reviewRequestLabel)/\(CodeHostKind.gitlab.reviewRequestLabel) linked" }
        let base = "\(identity.provider.reviewRequestLabel) \(identity.provider.reviewRequestNumberPrefix)\(identity.number)"
        guard let request = snapshot?.reviewRequest,
              request.provider == identity.provider,
              request.remote.host.caseInsensitiveCompare(identity.host) == .orderedSame,
              request.remote.repositorySlug.caseInsensitiveCompare(identity.repositorySlug) == .orderedSame,
              request.number == identity.number
        else { return base }
        let state: String
        switch request.state {
        case .open: state = "Open"
        case .closed: state = "Closed"
        case .merged: state = "Merged"
        }
        return "\(base) · \(state)"
    }
}

struct MissionAggregateSummary: Equatable {
    let aggregate: MissionAggregate
    let legs: [MissionLegPresentation]
    let statusCopy: String
    let diffCopy: String
    let attentionLegIDs: [MissionLegID]

    init(aggregate: MissionAggregate, legs: [MissionLegPresentation]) {
        self.aggregate = aggregate
        self.legs = legs.sorted { lhs, rhs in
            if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        statusCopy = Self.statusCopy(for: aggregate.legs)
        diffCopy = Self.diffCopy(for: self.legs.compactMap(\.diffCounts))
        attentionLegIDs = self.legs
            .filter { $0.state == .needsAttention }
            .map(\.id)
    }

    static func statusCopy(for legs: [MissionLeg]) -> String {
        let creating = legs.filter { $0.state == .creating }.count
        let working = legs.filter { $0.state == .running }.count
        let attention = legs.filter { $0.state == .needsAttention }.count
        let ready = legs.filter { $0.state == .ready }.count
        let parts = [
            countCopy(creating, singular: "creating", plural: "creating"),
            countCopy(working, singular: "working", plural: "working"),
            countCopy(attention, singular: "needs attention", plural: "need attention"),
            countCopy(ready, singular: "ready", plural: "ready"),
        ].compactMap { $0 }
        return parts.isEmpty ? "No legs" : parts.joined(separator: " · ")
    }

    private static func countCopy(_ count: Int, singular: String, plural: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    private static func diffCopy(for counts: [MissionDiffCounts]) -> String {
        guard !counts.isEmpty else { return "Changes unavailable" }
        let fileCount = counts.reduce(0) { $0 + $1.fileCount }
        let additions = counts.reduce(0) { $0 + $1.additions }
        let deletions = counts.reduce(0) { $0 + $1.deletions }
        let files = fileCount == 1 ? "1 file" : "\(fileCount) files"
        return "\(files) · +\(additions) −\(deletions)"
    }
}
