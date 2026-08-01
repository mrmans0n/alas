import Foundation
import Testing
@testable import Alas

@MainActor
struct MissionPresentationTests {
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
