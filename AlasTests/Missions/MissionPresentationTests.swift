import Foundation
import Testing
@testable import Alas

@MainActor
struct MissionPresentationTests {
    @Test func legPresentationUsesConfiguredProjectName() {
        let aggregate = Self.runningAggregate()
        let leg = aggregate.legs[0]

        let presentation = MissionLegPresentation(
            aggregate: aggregate,
            leg: leg,
            projectName: "Alas App",
            worktree: Self.worktree
        )

        #expect(presentation.projectName == "Alas App")
        #expect(presentation.projectID == leg.projectId)
    }

    @Test func legCardActionsRouteAgentToOwningLeg() {
        let legID = MissionLegID(rawValue: "mission-1-leg-server")
        var openedLegID: MissionLegID?
        var retryAgentLegID: MissionLegID?
        let actions = MissionLegCardActions(
            legID: legID,
            openAgent: { openedLegID = $0 },
            openChanges: { _ in },
            retryWorktree: { _ in },
            retryAgent: { retryAgentLegID = $0 },
            recoverWorktree: { _ in }
        )

        actions.openAgent()
        actions.retryAgent()

        #expect(openedLegID == legID)
        #expect(retryAgentLegID == legID)
    }

    @Test func legCardActionsRouteWorktreeRetryToOwningLeg() {
        let legID = MissionLegID(rawValue: "mission-1-leg-server")
        var retriedLegID: MissionLegID?
        let actions = MissionLegCardActions(
            legID: legID,
            openAgent: { _ in },
            openChanges: { _ in },
            retryWorktree: { retriedLegID = $0 },
            retryAgent: { _ in },
            recoverWorktree: { _ in }
        )

        actions.retryWorktree()

        #expect(retriedLegID == legID)
    }

    @Test func aggregateSummaryFoldsOrderedLegCards() {
        let aggregate = Self.threeLegAggregate()
        let presentations = aggregate.legs.map { leg in
            MissionLegPresentation(
                aggregate: aggregate,
                leg: leg,
                worktree: Self.worktree(for: leg),
                acpSummary: leg.id.rawValue == "mission-1-leg-app"
                    ? .init(agentID: "codex", agentName: "Codex", activity: .working)
                    : nil,
                diffCounts: Self.diffCounts(for: leg),
                availableACPAgentIDs: ["codex"]
            )
        }

        let summary = MissionAggregateSummary(aggregate: aggregate, legs: presentations)

        #expect(summary.statusCopy == "1 working · 1 needs attention · 1 ready")
        #expect(summary.diffCopy == "Changes unavailable")
        #expect(summary.legs.map(\.id.rawValue) == [
            "mission-1-leg-app",
            "mission-1-leg-sdk",
            "mission-1-leg-server",
        ])
        #expect(summary.attentionLegIDs.map(\.rawValue) == ["mission-1-leg-sdk"])
        #expect(summary.legs[0].agentCopy == "Codex · Working")
        #expect(summary.legs[1].stateLabel == "Needs attention")
        #expect(summary.legs[1].checkpointCopy == "ACP agent startup needs attention.")
        #expect(summary.legs[1].errorCopy == "Agent authentication is required.")
        #expect(summary.legs[1].actions.retryAgent)
        #expect(summary.legs[2].stateLabel == "Ready")
    }

    @Test func aggregateSummaryTotalsChangesOnlyWhenEveryLegHasCounts() {
        let aggregate = Self.threeLegAggregate()
        let presentations = aggregate.legs.map { leg in
            MissionLegPresentation(
                aggregate: aggregate,
                leg: leg,
                worktree: Self.worktree(for: leg),
                diffCounts: .init(fileCount: leg.ordinal + 1, additions: 5, deletions: 2)
            )
        }

        let summary = MissionAggregateSummary(aggregate: aggregate, legs: presentations)

        #expect(summary.diffCopy == "6 files · +15 −6")
    }

    @Test func completionConfirmationListsEveryUnfinishedLeg() {
        let aggregate = Self.threeLegAggregate()

        let message = MissionCompletionConfirmation.message(
            for: aggregate,
            projectNames: ["app": "Alas App", "sdk": "Alas SDK", "server": "Alas Server"]
        )

        #expect(message.contains("Unfinished legs:"))
        #expect(message.contains("• Alas App — mission/42-app — Working"))
        #expect(message.contains("• Alas SDK — mission/42-sdk — Needs attention"))
        #expect(!message.contains("Alas Server"))
    }

    @Test func missionPaneLookupKeepsPersistedQualifiedBase() {
        let aggregate = Self.runningAggregate()
        let leg = Self.leg(
            id: aggregate.legs[0].id,
            missionID: aggregate.mission.id,
            ordinal: 0,
            projectId: aggregate.legs[0].projectId,
            baseRef: "team/origin/main",
            baseRemoteName: "team/origin",
            branch: aggregate.legs[0].branch,
            worktreeId: aggregate.legs[0].worktreeId,
            state: aggregate.legs[0].state,
            setupCheckpoint: aggregate.legs[0].setupCheckpoint
        )

        #expect(MissionTabContext.baseBranch(for: leg) == "team/origin/main")
    }

    @Test func tabContextRejectsReplacementBranchAndUsesMissionBase() {
        let aggregate = Self.runningAggregate()
        var replacement = Self.worktree
        replacement.branch = "unrelated-branch"

        #expect(MissionTabContext.worktree(replacement, for: aggregate) == nil)
        #expect(MissionTabContext.baseBranch(for: aggregate, fallback: "global-main") == "origin/main")
    }

    @Test func creatingWorktreeExposesOnlyCheckpointRecoveryActions() {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .needsAttention
        aggregate.mission.attentionReason = "Git could not create the branch."

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: nil,
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.stateLabel == "Needs attention")
        #expect(presentation.checkpointCopy == "Worktree creation needs attention.")
        #expect(presentation.errorCopy == "Git could not create the branch.")
        #expect(presentation.actions.retryWorktree)
        #expect(!presentation.actions.retryAgent)
        #expect(!presentation.actions.openAgent)
        #expect(!presentation.actions.openChanges)
        #expect(presentation.actions.openIssue)
        #expect(presentation.actions.completeMission)
    }

    @Test func agentFailureAllowsWorktreeDestinationsAndReplacement() {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .needsAttention
        aggregate.mission.setupCheckpoint = .startingAgent
        aggregate.mission.attentionReason = "The stored agent is unavailable."
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].acpSessionId = "session-1"

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            availableACPAgentIDs: ["claude"]
        )

        #expect(presentation.actions.retryAgent)
        #expect(!presentation.actions.retryWorktree)
        #expect(!presentation.actions.openAgent)
        #expect(presentation.actions.openChanges)
        #expect(presentation.agentReplacementRequired)
        #expect(presentation.issueDestination == aggregate.issue.canonicalURL)
        #expect(presentation.agentDestination == "session-1")
        #expect(presentation.changesDestination == "worktree-1")
    }

    @Test func runningMissionExposesAgentChangesIssueAndRefresh() {
        let aggregate = Self.runningAggregate()
        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            acpSummary: .init(agentID: "codex", agentName: "Codex", activity: .working),
            diffCounts: .init(fileCount: 3, additions: 86, deletions: 14),
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.stateLabel == "Running")
        #expect(presentation.actions.openAgent)
        #expect(presentation.actions.openChanges)
        #expect(presentation.actions.openIssue)
        #expect(presentation.actions.refresh)
        #expect(!presentation.actions.retryAgent)
        #expect(presentation.actions.completeMission)
        #expect(presentation.agentCopy == "Codex · Working")
        #expect(presentation.diffCopy == "3 files · +86 −14")
    }

    @Test func refreshFailureKeepsSnapshotAndShowsStaleWarning() {
        var aggregate = Self.runningAggregate()
        aggregate.issue.refreshError = "gh is not authenticated"

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.staleSourceCopy == "Stored issue snapshot may be stale: gh is not authenticated")
        #expect(presentation.issueBody == aggregate.issue.body)
        #expect(presentation.actions.refresh)
    }

    @Test func linkedReviewUsesProviderLabelAndRemoteState() {
        var aggregate = Self.runningAggregate()
        aggregate.legs[0].reviewIdentity = .init(
            provider: .gitlab,
            host: "gitlab.example.com",
            repositorySlug: "platform/alas",
            number: 17,
            url: URL(string: "https://gitlab.example.com/platform/alas/-/merge_requests/17")!
        )

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            reviewSnapshot: Self.reviewSnapshot(provider: .gitlab, number: 17, state: .merged),
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.reviewCopy == "MR !17 · Merged")
        #expect(presentation.reviewDestination == aggregate.primaryLeg?.reviewIdentity?.url)
    }

    @Test func linkedReviewUsesRemoteStateAcrossRepositoryCasingChanges() {
        var aggregate = Self.runningAggregate()
        aggregate.legs[0].reviewIdentity = .init(
            provider: .gitlab,
            host: "gitlab.example.com",
            repositorySlug: "Platform/Alas",
            number: 17,
            url: URL(string: "https://gitlab.example.com/Platform/Alas/-/merge_requests/17")!
        )

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            reviewSnapshot: Self.reviewSnapshot(provider: .gitlab, number: 17, state: .merged),
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.reviewCopy == "MR !17 · Merged")
    }

    @Test func readyMissionExplainsWhyCompletionIsAvailable() {
        var aggregate = Self.runningAggregate()
        aggregate.mission.state = .readyToComplete
        aggregate.events.append(.init(
            id: "ready-event",
            missionID: aggregate.mission.id,
            legID: aggregate.primaryLeg?.id,
            kind: .ready,
            message: "PR #91 merged.",
            createdAt: Date(timeIntervalSince1970: 200)
        ))

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.stateLabel == "Ready to complete")
        #expect(presentation.readinessCopy == "PR #91 merged.")
        #expect(presentation.actions.completeMission)
        #expect(presentation.completionConfirmationRequired)
    }

    @Test func completedMissionKeepsDestinationsButHidesCompletionAction() {
        var aggregate = Self.runningAggregate()
        aggregate.mission.state = .completed
        aggregate.mission.completedAt = Date(timeIntervalSince1970: 300)

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.stateLabel == "Completed")
        #expect(!presentation.actions.completeMission)
        #expect(presentation.actions.openAgent)
        #expect(presentation.actions.openChanges)
        #expect(!presentation.completionConfirmationRequired)
    }

    @Test func missingWorktreeSurfacesExistingRecoveryWhenProvided() {
        var aggregate = Self.runningAggregate()
        aggregate.mission.state = .needsAttention
        aggregate.mission.attentionReason = "The Mission worktree is no longer available."

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: nil,
            worktreeRecoveryAvailable: true,
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.actions.recoverWorktree)
        #expect(presentation.actions.completeMission)
        #expect(!presentation.actions.openChanges)
        #expect(!presentation.actions.openAgent)
        #expect(presentation.worktreeRecovery == .recreateMissing)
    }

    @Test func completedMissionDoesNotOfferMissingWorktreeRecovery() {
        var aggregate = Self.runningAggregate()
        aggregate.mission.state = .completed
        aggregate.mission.completedAt = Date(timeIntervalSince1970: 300)

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: nil,
            worktreeRecoveryAvailable: true
        )

        #expect(presentation.worktreeRecovery == .none)
        #expect(!presentation.actions.recoverWorktree)
    }

    @Test func archivedWorktreeRecoveryRemainsASeparateRestoreAction() {
        let presentation = MissionTabPresentation(
            aggregate: Self.runningAggregate(),
            worktree: Self.worktree,
            worktreeArchived: true,
            worktreeRecoveryAvailable: true,
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.worktreeRecovery == .restoreArchived)
        #expect(!presentation.actions.openChanges)
    }

    @Test func archivedSecondaryLegOffersTheSameRestoreAction() {
        var aggregate = Self.runningAggregate()
        let primary = aggregate.legs[0]
        let secondary = MissionLeg(
            id: MissionLegID(rawValue: "mission-1-leg-2"),
            missionID: aggregate.mission.id,
            ordinal: 1,
            projectId: "project-2",
            baseRef: "upstream/trunk",
            branch: "fix/server-parser-crash",
            destinationPath: "/tmp/alas-server-mission",
            worktreeId: "worktree-2",
            agentId: "codex",
            acpSessionId: "session-2",
            initialPromptId: UUID(),
            pendingInitialPrompt: nil,
            reviewIdentity: nil,
            state: .ready,
            setupCheckpoint: .running
        )
        aggregate.legs = [primary, secondary]
        let worktree = Worktree(
            id: "worktree-2",
            projectId: secondary.projectId,
            name: secondary.branch,
            branch: secondary.branch,
            path: URL(fileURLWithPath: secondary.destinationPath),
            status: .clean,
            lastActivity: .now
        )

        let presentation = MissionLegPresentation(
            aggregate: aggregate,
            leg: secondary,
            worktree: worktree,
            worktreeArchived: true
        )

        #expect(presentation.actions.recoverWorktree)
    }

    @Test func headerAndLegUseStoredIssueIdentityAndCapturedDetails() {
        var aggregate = Self.runningAggregate()
        aggregate.issue = .init(
            identity: .init(
                provider: .github,
                host: "github.example.com",
                repositorySlug: "stored/mission-repo",
                number: 42
            ),
            canonicalURL: URL(string: "https://github.example.com/stored/mission-repo/issues/42")!,
            title: aggregate.issue.title,
            body: aggregate.issue.body,
            state: aggregate.issue.state,
            labels: aggregate.issue.labels,
            assignees: aggregate.issue.assignees,
            providerUpdatedAt: aggregate.issue.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 123),
            refreshError: aggregate.issue.refreshError
        )

        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: Self.worktree,
            projectName: "Incorrect project display name",
            availableACPAgentIDs: ["codex"]
        )

        #expect(presentation.repositoryName == "stored/mission-repo")
        #expect(presentation.issueCapturedAt == Date(timeIntervalSince1970: 123))
        #expect(presentation.baseCopy == "origin/main")
        #expect(presentation.destinationCopy == "/tmp/alas-mission")
    }

    private static let worktree = Worktree(
        id: "worktree-1",
        projectId: "project-1",
        name: "fix/parser-crash",
        branch: "fix/parser-crash",
        path: URL(fileURLWithPath: "/tmp/alas-mission"),
        status: .dirty,
        lastActivity: Date(timeIntervalSince1970: 100)
    )

    private static func runningAggregate() -> MissionAggregate {
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        return aggregate
    }

    private static func threeLegAggregate() -> MissionAggregate {
        let missionID = MissionID(rawValue: "mission-1")
        let appLegID = MissionLegID(rawValue: "mission-1-leg-app")
        let sdkLegID = MissionLegID(rawValue: "mission-1-leg-sdk")
        let serverLegID = MissionLegID(rawValue: "mission-1-leg-server")
        return MissionAggregate(
            mission: MissionRecord(
                id: missionID,
                title: "Fix parser crash",
                state: .running,
                setupCheckpoint: .running,
                primaryLegID: appLegID,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 120),
                completedAt: nil
            ),
            issue: MissionFixtures.issue(),
            legs: [
                Self.leg(
                    id: appLegID,
                    missionID: missionID,
                    ordinal: 0,
                    projectId: "app",
                    branch: "mission/42-app",
                    worktreeId: "wt-app",
                    state: .running,
                    setupCheckpoint: .running,
                    acpSessionId: "session-app"
                ),
                Self.leg(
                    id: sdkLegID,
                    missionID: missionID,
                    ordinal: 1,
                    projectId: "sdk",
                    branch: "mission/42-sdk",
                    worktreeId: "wt-sdk",
                    state: .needsAttention,
                    setupCheckpoint: .startingAgent,
                    attentionReason: "Agent authentication is required."
                ),
                Self.leg(
                    id: serverLegID,
                    missionID: missionID,
                    ordinal: 2,
                    projectId: "server",
                    branch: "mission/42-server",
                    worktreeId: "wt-server",
                    state: .ready,
                    setupCheckpoint: .running,
                    readinessEvidence: .init(
                        kind: .mergedReview,
                        observedAt: Date(timeIntervalSince1970: 130)
                    )
                ),
            ],
            events: [
                MissionFixtures.event(
                    id: "mission-1-event-1",
                    missionID: missionID,
                    legID: appLegID,
                    kind: .created
                )
            ]
        )
    }

    private static func leg(
        id: MissionLegID,
        missionID: MissionID,
        ordinal: Int,
        projectId: String,
        baseRef: String = "origin/main",
        baseRemoteName: String? = "origin",
        branch: String,
        worktreeId: String?,
        state: MissionLegState,
        setupCheckpoint: MissionSetupCheckpoint,
        attentionReason: String? = nil,
        acpSessionId: String? = nil,
        readinessEvidence: MissionLegReadinessEvidence? = nil
    ) -> MissionLeg {
        MissionLeg(
            id: id,
            missionID: missionID,
            ordinal: ordinal,
            projectId: projectId,
            baseRef: baseRef,
            baseRemoteName: baseRemoteName,
            branch: branch,
            destinationPath: "/tmp/\(projectId)",
            worktreeId: worktreeId,
            agentId: "codex",
            acpSessionId: acpSessionId,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pendingInitialPrompt: nil,
            reviewIdentity: nil,
            state: state,
            setupCheckpoint: setupCheckpoint,
            attentionReason: attentionReason,
            readinessEvidence: readinessEvidence,
            createdAt: Date(timeIntervalSince1970: 100 + TimeInterval(ordinal)),
            updatedAt: Date(timeIntervalSince1970: 120 + TimeInterval(ordinal))
        )
    }

    private static func worktree(for leg: MissionLeg) -> Worktree? {
        guard let worktreeId = leg.worktreeId else { return nil }
        return Worktree(
            id: worktreeId,
            projectId: leg.projectId,
            name: leg.branch,
            branch: leg.branch,
            path: URL(fileURLWithPath: leg.destinationPath),
            status: .dirty,
            lastActivity: Date(timeIntervalSince1970: 100)
        )
    }

    private static func diffCounts(for leg: MissionLeg) -> MissionDiffCounts? {
        switch leg.projectId {
        case "app":
            .init(fileCount: 2, additions: 10, deletions: 4)
        case "sdk":
            .init(fileCount: 3, additions: 5, deletions: 3)
        default:
            nil
        }
    }

    private static func reviewSnapshot(
        provider: CodeHostKind,
        number: Int,
        state: ReviewRequestState
    ) -> ReviewLoopSnapshot {
        let host = provider == .github ? "github.com" : "gitlab.example.com"
        let remote = CodeHostRemote(
            kind: provider,
            host: host,
            owner: "platform",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://\(host)/platform/alas")!
        )
        return ReviewLoopSnapshot(
            local: .init(
                branchName: "fix/parser-crash",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                needsPush: false
            ),
            remote: remote,
            reviewRequest: .init(
                remote: remote,
                number: number,
                title: "Mission review",
                url: remote.reviewRequestURL(number: number),
                state: state,
                isDraft: false,
                headRefName: "fix/parser-crash",
                baseRefName: "main",
                reviewDecision: .approved,
                mergeState: .clean,
                checks: [],
                threads: []
            ),
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
    }
}
