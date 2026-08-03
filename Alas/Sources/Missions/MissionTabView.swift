import AppKit
import SwiftUI

struct MissionDiffCounts: Equatable {
    let fileCount: Int
    let additions: Int
    let deletions: Int

    init(fileCount: Int, additions: Int, deletions: Int) {
        self.fileCount = fileCount
        self.additions = additions
        self.deletions = deletions
    }

    init(changes: [ChangedFile]) {
        fileCount = changes.count
        additions = changes.reduce(0) { $0 + $1.add }
        deletions = changes.reduce(0) { $0 + $1.del }
    }
}

enum MissionAgentActivity: Equatable {
    case unavailable
    case connecting
    case ready
    case working
    case needsInput
    case disconnected
    case failed

    var label: String {
        switch self {
        case .unavailable: "Unavailable"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .working: "Working"
        case .needsInput: "Needs input"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        }
    }
}

struct MissionACPSummary: Equatable {
    let agentID: String
    let agentName: String
    let activity: MissionAgentActivity

    @MainActor
    init(session: ACPSession, agentName: String) {
        agentID = session.agentId
        self.agentName = agentName
        switch session.agentState {
        case .idle, .spawning:
            activity = .connecting
        case .ready:
            switch session.transcript.streamingState {
            case .idle: activity = .ready
            case .sending, .streaming: activity = .working
            case .awaitingPermission, .awaitingInput: activity = .needsInput
            }
        case .disconnected:
            activity = .disconnected
        case .failed:
            activity = .failed
        }
    }

    init(agentID: String, agentName: String, activity: MissionAgentActivity) {
        self.agentID = agentID
        self.agentName = agentName
        self.activity = activity
    }
}

struct MissionTabPresentation: Equatable {
    enum WorktreeRecovery: Equatable {
        case none
        case restoreArchived
        case recreateMissing
    }

    enum StateTone: Equatable {
        case progress
        case success
        case warning
        case attention
        case complete
    }

    struct Actions: Equatable {
        let openAgent: Bool
        let openChanges: Bool
        let openIssue: Bool
        let refresh: Bool
        let retryWorktree: Bool
        let retryAgent: Bool
        let recoverWorktree: Bool
        let completeMission: Bool
    }

    let providerName: String
    let repositoryName: String
    let issueNumberCopy: String
    let title: String
    let issueCapturedAt: Date
    let stateLabel: String
    let stateTone: StateTone
    let checkpointCopy: String?
    let errorCopy: String?
    let staleSourceCopy: String?
    let issueBody: String
    let labels: [String]
    let assignees: [String]
    let branchCopy: String
    let baseCopy: String
    let destinationCopy: String
    let agentCopy: String
    let diffCopy: String
    let reviewCopy: String
    let readinessCopy: String
    let events: [MissionEvent]
    let actions: Actions
    let worktreeRecovery: WorktreeRecovery
    let issueDestination: URL
    let agentDestination: String?
    let changesDestination: String?
    let reviewDestination: URL?
    let agentReplacementRequired: Bool
    let completionConfirmationRequired: Bool

    init(
        aggregate: MissionAggregate,
        worktree: Worktree?,
        acpSummary: MissionACPSummary? = nil,
        diffCounts: MissionDiffCounts? = nil,
        reviewSnapshot: ReviewLoopSnapshot? = nil,
        projectName _: String? = nil,
        worktreeArchived: Bool = false,
        worktreeRecoveryAvailable: Bool = false,
        availableACPAgentIDs: Set<String> = []
    ) {
        let mission = aggregate.mission
        let issue = aggregate.issue
        let leg = aggregate.primaryLeg
        providerName = issue.identity.provider.displayName
        repositoryName = issue.identity.repositorySlug
        issueNumberCopy = "#\(issue.identity.number)"
        title = mission.title
        issueCapturedAt = issue.capturedAt
        stateLabel = Self.stateLabel(mission.state)
        stateTone = Self.stateTone(mission.state)
        checkpointCopy = Self.checkpointCopy(mission)
        errorCopy = mission.attentionReason
        staleSourceCopy = issue.refreshError.map {
            "Stored issue snapshot may be stale: \($0)"
        }
        issueBody = issue.body
        labels = issue.labels
        assignees = issue.assignees
        branchCopy = worktree?.branch ?? leg?.branch ?? "Worktree unavailable"
        baseCopy = leg?.baseRef ?? ""
        destinationCopy = worktree?.path.path ?? leg?.destinationPath ?? ""
        if let acpSummary {
            agentCopy = "\(acpSummary.agentName) · \(acpSummary.activity.label)"
        } else if let agentID = leg?.agentId {
            agentCopy = "\(agentID) · Session unavailable"
        } else {
            agentCopy = "No ACP agent"
        }
        if let diffCounts {
            let files = diffCounts.fileCount == 1 ? "1 file" : "\(diffCounts.fileCount) files"
            diffCopy = "\(files) · +\(diffCounts.additions) −\(diffCounts.deletions)"
        } else {
            diffCopy = "Changes unavailable"
        }
        let linkedReview = leg?.reviewIdentity
        reviewCopy = Self.reviewCopy(identity: linkedReview, snapshot: reviewSnapshot)
        reviewDestination = linkedReview?.url
        readinessCopy = Self.readinessCopy(aggregate)
        events = aggregate.events.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id < rhs.id
        }

        let isAttention = mission.state == .needsAttention
        let retryWorktree = isAttention && mission.setupCheckpoint == .creatingWorktree
        let retryAgent = isAttention && mission.setupCheckpoint == .startingAgent
        let hasUsableWorktree = worktree != nil && !worktreeArchived
        let openAgent = hasUsableWorktree
            && leg?.acpSessionId != nil
            && mission.setupCheckpoint == .running
        let canComplete = [MissionState.running, .needsAttention, .readyToComplete]
            .contains(mission.state)
        let recovery: WorktreeRecovery
        if worktreeArchived, worktree != nil {
            recovery = .restoreArchived
        } else if worktree == nil,
                  worktreeRecoveryAvailable,
                  mission.state == .needsAttention,
                  mission.setupCheckpoint == .running,
                  mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage {
            recovery = .recreateMissing
        } else {
            recovery = .none
        }
        worktreeRecovery = recovery
        actions = Actions(
            openAgent: openAgent,
            openChanges: hasUsableWorktree,
            openIssue: true,
            refresh: true,
            retryWorktree: retryWorktree,
            retryAgent: retryAgent,
            recoverWorktree: recovery != .none,
            completeMission: canComplete
        )
        issueDestination = issue.canonicalURL
        agentDestination = leg?.acpSessionId
        changesDestination = worktree?.id
        agentReplacementRequired = retryAgent
            && leg.map { !availableACPAgentIDs.contains($0.agentId) } == true
        completionConfirmationRequired = canComplete
    }

    private static func stateLabel(_ state: MissionState) -> String {
        switch state {
        case .creating: "Creating"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .readyToComplete: "Ready to complete"
        case .completed: "Completed"
        }
    }

    private static func stateTone(_ state: MissionState) -> StateTone {
        switch state {
        case .creating: .progress
        case .running: .success
        case .needsAttention: .attention
        case .readyToComplete: .warning
        case .completed: .complete
        }
    }

    private static func checkpointCopy(_ mission: MissionRecord) -> String? {
        switch (mission.state, mission.setupCheckpoint) {
        case (.creating, .creatingWorktree): "Creating worktree…"
        case (.creating, .startingAgent): "Starting ACP agent…"
        case (.creating, .running): "Finalizing Mission setup…"
        case (.needsAttention, .creatingWorktree): "Worktree creation needs attention."
        case (.needsAttention, .startingAgent): "ACP agent startup needs attention."
        case (.needsAttention, .running): "Mission needs attention."
        default: nil
        }
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

    private static func readinessCopy(_ aggregate: MissionAggregate) -> String {
        switch aggregate.mission.state {
        case .readyToComplete:
            return aggregate.events
                .last(where: { $0.kind == .ready })?.message
                ?? "A completion condition was detected. Completion remains a user action."
        case .completed:
            return "Mission completed. Provider issue and worktree state were left unchanged."
        case .creating:
            return "Setup must finish before readiness can be evaluated."
        case .running, .needsAttention:
            return "Ready when the linked PR/MR merges or the worktree is archived in Alas. Completion remains a user action."
        }
    }
}

enum MissionTabContext {
    static func worktree(_ candidate: Worktree?, for aggregate: MissionAggregate) -> Worktree? {
        guard let candidate, let leg = aggregate.primaryLeg,
              candidate.projectId == leg.projectId,
              candidate.branch == leg.branch,
              leg.worktreeId == nil || candidate.id == leg.worktreeId
        else { return nil }
        return candidate
    }

    static func baseBranch(for aggregate: MissionAggregate, fallback: String) -> String {
        aggregate.primaryLeg?.baseRef ?? fallback
    }

    static func rightPaneActivationKey(
        worktreeID: String,
        branch: String,
        baseRef: String,
        comparisonMode: String,
        worktreeArchived: Bool
    ) -> String {
        "\(worktreeID)\u{0000}\(branch)\u{0000}\(baseRef)\u{0000}\(comparisonMode)\u{0000}\(worktreeArchived)"
    }
}

struct MissionTabView: View {
    @Bindable var state: AppState
    let worktree: Worktree?
    let tabState: MissionTabState

    @State private var completionConfirmationPresented = false
    @State private var agentPickerPresented = false
    @State private var agentPickerLegID: MissionLegID?
    @State private var addLegPresented = false
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let aggregate = state.missions.aggregate(id: tabState.missionID) {
                missionContent(aggregate)
            } else {
                ContentUnavailableView(
                    "Mission unavailable",
                    systemImage: "scope",
                    description: Text("The Mission record could not be loaded.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .confirmationDialog(
            "Complete Mission?",
            isPresented: $completionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Complete Mission") {
                Task { await state.missions.complete(tabState.missionID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only marks the Mission completed in Alas. It does not stop the agent, archive the worktree, merge code, or change the source issue.")
        }
        .popover(isPresented: $agentPickerPresented) {
            MissionAgentReplacementPopover(
                agents: enabledACPAgents,
                storedAgentID: agentPickerLeg?.agentId ?? ""
            ) { agentID in
                guard let legID = agentPickerLegID else { return }
                Task { await retryAgent(legID: legID, agentID: agentID) }
            }
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $addLegPresented) {
            AddMissionLegDialog(
                presented: $addLegPresented,
                state: state,
                missionID: tabState.missionID
            )
            .environment(\.theme, theme)
        }
    }

    private func missionContent(_ aggregate: MissionAggregate) -> some View {
        let primaryWorktree = state.missionWorktree(worktree, for: aggregate)
        let primaryRightPane = primaryWorktree.flatMap { state.rightPaneStore.activeState(worktreeId: $0.id) }
        let session = linkedSession(aggregate)
        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: primaryWorktree,
            acpSummary: session.map {
                MissionACPSummary(session: $0, agentName: agentName(for: $0.agentId))
            },
            diffCounts: primaryRightPane.map { MissionDiffCounts(changes: $0.displayChanges) },
            reviewSnapshot: primaryRightPane?.reviewLoop.snapshot,
            worktreeArchived: worktreeIsArchived,
            worktreeRecoveryAvailable: primaryWorktree == nil
                && aggregate.primaryLeg.map { leg in state.projects.contains { $0.id == leg.projectId } } == true,
            availableACPAgentIDs: Set(enabledACPAgents.map(\.id))
        )
        let legPresentations = aggregate.legs.map { leg in
            let legWorktree = worktree(for: leg, aggregate: aggregate)
            let legRightPane = legWorktree.flatMap { state.rightPaneStore.activeState(worktreeId: $0.id) }
            let legSession = linkedSession(aggregate: aggregate, leg: leg, worktree: legWorktree)
            return MissionLegPresentation(
                aggregate: aggregate,
                leg: leg,
                worktree: legWorktree,
                acpSummary: legSession.map {
                    MissionACPSummary(session: $0, agentName: agentName(for: $0.agentId))
                },
                diffCounts: legRightPane.map { MissionDiffCounts(changes: $0.displayChanges) },
                reviewSnapshot: legRightPane?.reviewLoop.snapshot,
                worktreeArchived: legWorktree.map { worktreeIsArchived($0) } ?? false,
                worktreeRecoveryAvailable: legWorktree == nil && state.projects.contains { $0.id == leg.projectId },
                availableACPAgentIDs: Set(enabledACPAgents.map(\.id))
            )
        }
        let summary = MissionAggregateSummary(aggregate: aggregate, legs: legPresentations)

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                MissionHeaderSection(presentation: presentation, summary: summary)
                ForEach(summary.legs) { leg in
                    let legSession = linkedSession(for: leg, aggregate: aggregate)
                    MissionLegSection(
                        presentation: leg,
                        session: legSession,
                        agentName: legSession.map { agentName(for: $0.agentId) },
                        onOpenAgent: { openAgent(legID: leg.id) },
                        onOpenChanges: { openChanges(legID: leg.id) },
                        onOpenIssue: { NSWorkspace.shared.open(presentation.issueDestination) },
                        onOpenReview: {
                            if let url = leg.reviewDestination {
                                NSWorkspace.shared.open(url)
                            }
                        },
                        onRetryWorktree: { retryWorktree(legID: leg.id) },
                        onRetryAgent: {
                            agentPickerLegID = leg.id
                            agentPickerPresented = true
                        },
                        onRecoverWorktree: { recoverWorktree(legID: leg.id) }
                    )
                }
                if aggregate.mission.state == .running {
                    Button("Add Leg") { addLegPresented = true }
                        .buttonStyle(.borderedProminent)
                }
                MissionIssueContextSection(presentation: presentation, onRefresh: refresh)
                MissionActivitySection(events: presentation.events)
                MissionReadinessSection(
                    presentation: presentation,
                    onRetryWorktree: { retryWorktree(legID: aggregate.mission.primaryLegID) },
                    onRetryAgent: {
                        agentPickerLegID = aggregate.mission.primaryLegID
                        agentPickerPresented = true
                    },
                    onRecoverWorktree: { recoverWorktree(legID: aggregate.mission.primaryLegID) },
                    onCompleteMission: { completionConfirmationPresented = true }
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var enabledACPAgents: [AgentDefinition] {
        NewWorktreeDialog.acpCapableAgents(from: state.agentRegistry.enabled())
    }

    private var worktreeIsArchived: Bool {
        guard let aggregate = state.missions.aggregate(id: tabState.missionID),
              let worktree = state.missionWorktree(worktree, for: aggregate)
        else { return false }
        return worktreeIsArchived(worktree)
    }

    private func linkedSession(_ aggregate: MissionAggregate) -> ACPSession? {
        guard let worktree = state.missionWorktree(worktree, for: aggregate),
              let id = aggregate.primaryLeg?.acpSessionId,
              let manager = state.acpManager(forWorktreeId: worktree.id)
        else { return nil }
        return manager.liveSession(for: id) ?? manager.placeholderSession(id: id)
    }

    private var agentPickerLeg: MissionLeg? {
        guard let aggregate = state.missions.aggregate(id: tabState.missionID),
              let legID = agentPickerLegID
        else { return nil }
        return leg(in: aggregate, id: legID)
    }

    private func linkedSession(for presentation: MissionLegPresentation, aggregate: MissionAggregate) -> ACPSession? {
        guard let leg = aggregate.legs.first(where: { $0.id == presentation.id }) else { return nil }
        return linkedSession(aggregate: aggregate, leg: leg, worktree: worktree(for: leg, aggregate: aggregate))
    }

    private func linkedSession(aggregate _: MissionAggregate, leg: MissionLeg, worktree: Worktree?) -> ACPSession? {
        guard let worktree,
              let id = leg.acpSessionId,
              let manager = state.acpManager(forWorktreeId: worktree.id)
        else { return nil }
        return manager.liveSession(for: id) ?? manager.placeholderSession(id: id)
    }

    private func agentName(for id: String) -> String {
        state.agent(id: id)?.displayName
            ?? AgentBuiltins.entry(id: id)?.displayName
            ?? id
    }

    private func openAgent(legID: MissionLegID) {
        guard let aggregate = state.missions.aggregate(id: tabState.missionID),
              let leg = leg(in: aggregate, id: legID),
              let worktree = worktree(for: leg, aggregate: aggregate),
              !worktreeIsArchived(worktree),
              let sessionID = leg.acpSessionId
        else { return }
        state.focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        Task { await state.openExistingACPSession(sessionId: sessionID) }
    }

    private func openChanges(legID: MissionLegID) {
        guard let aggregate = state.missions.aggregate(id: tabState.missionID),
              let leg = leg(in: aggregate, id: legID),
              let worktree = worktree(for: leg, aggregate: aggregate)
        else { return }
        Task { await state.openMissionChanges(worktree: worktree, missionID: tabState.missionID, legID: leg.id) }
    }

    private func refresh() {
        Task { await state.refreshMission(tabState.missionID) }
    }

    private func retryWorktree(legID: MissionLegID) {
        Task { await state.missions.retry(tabState.missionID, legID: legID) }
    }

    private func retryAgent(legID: MissionLegID, agentID: String) async {
        await state.missions.retry(tabState.missionID, legID: legID, agentId: agentID)
    }

    private func recoverWorktree(legID: MissionLegID) {
        let aggregate = state.missions.aggregate(id: tabState.missionID)
        guard let aggregate,
              let leg = leg(in: aggregate, id: legID)
        else { return }
        guard let worktree = worktree(for: leg, aggregate: aggregate) else {
            Task { await state.missions.retry(tabState.missionID, legID: leg.id) }
            return
        }
        guard worktreeIsArchived(worktree) else { return }
        state.unarchiveWorktree(projectId: worktree.projectId, path: worktree.path)
        state.focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
    }

    private func leg(in aggregate: MissionAggregate, id: MissionLegID) -> MissionLeg? {
        return aggregate.legs.first { $0.id == id }
    }

    private func worktree(for leg: MissionLeg, aggregate: MissionAggregate) -> Worktree? {
        let candidate: Worktree?
        if let worktree,
           worktree.projectId == leg.projectId,
           worktree.branch == leg.branch,
           leg.worktreeId == nil || worktree.id == leg.worktreeId {
            candidate = worktree
        } else {
            candidate = state.missionWorktreeAtDestination(
                projectID: leg.projectId,
                destinationPath: leg.destinationPath
            )
        }
        guard let candidate,
              candidate.projectId == leg.projectId,
              candidate.branch == leg.branch,
              leg.worktreeId == nil || candidate.id == leg.worktreeId
        else { return nil }
        guard let persistedLineageID = leg.worktreeLineageID,
              candidate.lineageID == persistedLineageID
        else { return nil }
        guard aggregate.mission.state == .completed else { return candidate }
        let candidatePath = candidate.path.standardizedFileURL.path
        let ownedByALaterMission = state.missions.aggregates.contains { other in
            guard other.mission.id != aggregate.mission.id,
                  other.mission.createdAt > aggregate.mission.createdAt
            else { return false }
            return other.legs.contains { otherLeg in
                guard otherLeg.projectId == candidate.projectId else { return false }
                return otherLeg.worktreeId == candidate.id
                    || URL(fileURLWithPath: otherLeg.destinationPath).standardizedFileURL.path == candidatePath
            }
        }
        return ownedByALaterMission ? nil : candidate
    }

    private func worktreeIsArchived(_ worktree: Worktree) -> Bool {
        state.projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path)
    }
}

private struct MissionHeaderSection: View {
    let presentation: MissionTabPresentation
    let summary: MissionAggregateSummary
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(presentation.providerName.uppercased()) · \(presentation.repositoryName) \(presentation.issueNumberCopy)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("fg-dim"))
                    .accessibilityIdentifier("mission-header-repository")
                    .background(MissionAccessibilityMarker(identifier: "mission-header-repository"))
                Text(presentation.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.color("fg"))
                    .textSelection(.enabled)
                Text("Captured \(presentation.issueCapturedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-dim"))
                    .accessibilityIdentifier("mission-header-captured-at")
                    .background(MissionAccessibilityMarker(identifier: "mission-header-captured-at"))
                HStack(spacing: 8) {
                    Text(summary.statusCopy)
                    Text(summary.diffCopy)
                }
                .font(.caption)
                .foregroundStyle(theme.color("fg-dim"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MissionStateChip(label: presentation.stateLabel, tone: presentation.stateTone)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MissionStateChip: View {
    let label: String
    let tone: MissionTabPresentation.StateTone
    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .progress: theme.color("accent")
        case .success: theme.color("add")
        case .warning: theme.color("mod")
        case .attention: theme.color("del")
        case .complete: theme.color("fg-muted")
        }
    }
}

private struct MissionLegSection: View {
    let presentation: MissionLegPresentation
    let session: ACPSession?
    let agentName: String?
    let onOpenAgent: () -> Void
    let onOpenChanges: () -> Void
    let onOpenIssue: () -> Void
    let onOpenReview: () -> Void
    let onRetryWorktree: () -> Void
    let onRetryAgent: () -> Void
    let onRecoverWorktree: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.projectID)
                    .font(.headline)
                Spacer()
                MissionStateChip(label: presentation.stateLabel, tone: presentation.stateTone)
                Text(presentation.branchCopy)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.color("fg-dim"))
                    .textSelection(.enabled)
            }
            HStack(spacing: 14) {
                if let session, let agentName {
                    MissionLiveAgentStatus(session: session, agentName: agentName)
                } else {
                    Text(presentation.agentCopy)
                }
                Text(presentation.diffCopy)
                if let reviewDestination = presentation.reviewDestination {
                    Button(presentation.reviewCopy, action: onOpenReview)
                        .buttonStyle(.link)
                        .help(reviewDestination.absoluteString)
                } else {
                    Text(presentation.reviewCopy)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.color("fg-dim"))
            VStack(alignment: .leading, spacing: 4) {
                Text("Base: \(presentation.baseCopy)")
                    .accessibilityIdentifier("mission-leg-base")
                    .background(MissionAccessibilityMarker(identifier: "mission-leg-base"))
                Text("Worktree: \(presentation.destinationCopy)")
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mission-leg-destination")
                    .background(MissionAccessibilityMarker(identifier: "mission-leg-destination"))
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(theme.color("fg-dim"))
            HStack(spacing: 8) {
                if presentation.agentDestination != nil {
                    Button("Open Agent", action: onOpenAgent)
                        .disabled(!presentation.actions.openAgent)
                }
                if presentation.changesDestination != nil {
                    Button("Open Changes", action: onOpenChanges)
                        .disabled(!presentation.actions.openChanges)
                }
                Button("Open Issue", action: onOpenIssue)
                if presentation.actions.retryWorktree {
                    Button("Retry Worktree", action: onRetryWorktree)
                }
                if presentation.actions.retryAgent {
                    Button("Retry Agent", action: onRetryAgent)
                }
                if presentation.actions.recoverWorktree {
                    Button("Recover Worktree", action: onRecoverWorktree)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MissionLiveAgentStatus: View {
    @ObservedObject var session: ACPSession
    let agentName: String

    var body: some View {
        let summary = MissionACPSummary(session: session, agentName: agentName)
        Text("\(summary.agentName) · \(summary.activity.label)")
    }
}

private struct MissionIssueContextSection: View {
    let presentation: MissionTabPresentation
    let onRefresh: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ISSUE CONTEXT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                Spacer()
                Button("Refresh", action: onRefresh)
                    .buttonStyle(.borderless)
                    .disabled(!presentation.actions.refresh)
            }
            ACPMarkdownText(
                raw: presentation.issueBody,
                typography: .init(fontFamily: "", fontSize: 12)
            )
            .foregroundStyle(theme.color("fg"))
            .textSelection(.enabled)
            if !presentation.labels.isEmpty {
                Text(presentation.labels.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-dim"))
            }
            if !presentation.assignees.isEmpty {
                Text("Assigned to \(presentation.assignees.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-dim"))
            }
            if let stale = presentation.staleSourceCopy {
                Label(stale, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.color("mod"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-0"))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
    }
}

private struct MissionActivitySection: View {
    let events: [MissionEvent]
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
            ForEach(events, id: \.id) { event in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(event.createdAt, style: .time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                    Text(event.message)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("fg-dim"))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MissionReadinessSection: View {
    let presentation: MissionTabPresentation
    let onRetryWorktree: () -> Void
    let onRetryAgent: () -> Void
    let onRecoverWorktree: () -> Void
    let onCompleteMission: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let checkpoint = presentation.checkpointCopy {
                Text(checkpoint)
                    .font(.headline)
                    .foregroundStyle(theme.color("fg"))
            }
            if let error = presentation.errorCopy {
                Text(error)
                    .font(.body)
                    .foregroundStyle(theme.color("del"))
                    .textSelection(.enabled)
            }
            Text(presentation.readinessCopy)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-dim"))
            HStack(spacing: 8) {
                if presentation.actions.retryWorktree {
                    Button("Retry Worktree", action: onRetryWorktree)
                }
                if presentation.actions.retryAgent {
                    Button("Retry Agent", action: onRetryAgent)
                }
                if presentation.actions.recoverWorktree {
                    Button(
                        presentation.worktreeRecovery == .recreateMissing
                            ? "Recreate Worktree"
                            : "Restore Worktree",
                        action: onRecoverWorktree
                    )
                }
                if presentation.actions.completeMission {
                    Button("Complete Mission", action: onCompleteMission)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.color("bg-2"))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        }
    }
}

private struct MissionAgentReplacementPopover: View {
    let agents: [AgentDefinition]
    let onRetry: (String) -> Void
    @State private var selectedAgentID: String
    @Environment(\.dismiss) private var dismiss

    init(
        agents: [AgentDefinition],
        storedAgentID: String,
        onRetry: @escaping (String) -> Void
    ) {
        self.agents = agents
        self.onRetry = onRetry
        let initial = agents.contains(where: { $0.id == storedAgentID })
            ? storedAgentID
            : agents.first?.id ?? ""
        _selectedAgentID = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Retry ACP Agent")
                .font(.headline)
            Text("Choose an enabled ACP agent. Retrying starts only the agent checkpoint and keeps the existing worktree.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("ACP agent", selection: $selectedAgentID) {
                ForEach(agents) { agent in
                    Label {
                        Text(agent.displayName)
                    } icon: {
                        Image(nsImage: AgentLogoView.menuImage(for: agent, size: 14))
                    }
                    .tag(agent.id)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Retry Agent") {
                    onRetry(selectedAgentID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAgentID.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

struct MissionAccessibilityMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.setAccessibilityIdentifier(identifier)
    }
}
