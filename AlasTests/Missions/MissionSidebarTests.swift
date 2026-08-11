import Foundation
import Testing
@testable import Alas

struct MissionSidebarTests {
    @Test func orphanedMissionsKeepTheWorkspaceVisibleWithoutProjects() {
        #expect(RootWorkspaceVisibilityPolicy.showsWorkspace(
            hasProjects: false,
            missionsEnabled: true,
            hasMissions: true,
            hasActiveMissionTab: false
        ))
    }

    @Test func activePersistedMissionTabKeepsTheWorkspaceVisibleWithoutProjectsOrMissions() {
        #expect(RootWorkspaceVisibilityPolicy.showsWorkspace(
            hasProjects: false,
            missionsEnabled: true,
            hasMissions: false,
            hasActiveMissionTab: true
        ))
    }

    @Test func disabledMissionsDoNotKeepAnEmptyWorkspaceVisible() {
        #expect(!RootWorkspaceVisibilityPolicy.showsWorkspace(
            hasProjects: false,
            missionsEnabled: false,
            hasMissions: true,
            hasActiveMissionTab: true
        ))
    }

    @Test func missionAppearsInEverySpaceContainingItsProject() {
        let mission = Self.mission(projectId: "alas", state: .running)

        #expect(MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["alas", "other"],
            existingProjectIds: ["alas"]
        ))
        #expect(!MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["other"],
            existingProjectIds: ["alas", "other"]
        ))
    }

    @Test func multiLegMissionAppearsInAnySpaceContainingALegProject() {
        let mission = Self.multiLegMission()

        #expect(MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["sdk"],
            existingProjectIds: ["app", "sdk", "server"]
        ))
        #expect(!MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["docs"],
            existingProjectIds: ["app", "sdk", "server", "docs"]
        ))
    }

    @Test func orphanedMissionRemainsReachableInEverySpace() {
        let mission = Self.mission(projectId: "removed", state: .needsAttention)

        #expect(MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["alas"],
            existingProjectIds: ["alas"]
        ))
    }

    @Test func partiallyOrphanedMultiLegMissionStaysScopedToSurvivingProjects() {
        let mission = Self.multiLegMission()

        #expect(MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["sdk"],
            existingProjectIds: ["sdk", "server", "docs"]
        ))
        #expect(!MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["docs"],
            existingProjectIds: ["sdk", "server", "docs"]
        ))
    }

    @Test func activeMissionsSortByLatestActivity() {
        let rows = MissionSidebarModel.make(
            aggregates: [
                Self.mission(id: "older", updatedAt: 100),
                Self.mission(id: "newer", updatedAt: 200)
            ],
            activeProjectIds: ["project-1"],
            existingProjectIds: ["project-1"],
            knownWorktreeIds: []
        )

        #expect(rows.active.map(\.updatedAt) == [
            Date(timeIntervalSince1970: 200),
            Date(timeIntervalSince1970: 100)
        ])
    }

    @Test func completedMissionsLiveInSeparateCollapsedGroup() {
        let rows = MissionSidebarModel.make(
            aggregates: [
                Self.mission(id: "active", state: .readyToComplete),
                Self.mission(id: "done", state: .completed)
            ],
            activeProjectIds: ["project-1"],
            existingProjectIds: ["project-1"],
            knownWorktreeIds: []
        )

        #expect(rows.active.map(\.id.rawValue) == ["active"])
        #expect(rows.completed.map(\.id.rawValue) == ["done"])
    }

    @Test func rowCopiesMatchMissionStateAndProvider() {
        let creating = MissionSidebarRow(aggregate: Self.mission(id: "creating", state: .creating))
        let running = MissionSidebarRow(aggregate: Self.mission(id: "running", state: .running))
        let needsAttention = MissionSidebarRow(aggregate: Self.mission(id: "attention", state: .needsAttention))
        let ready = MissionSidebarRow(aggregate: Self.mission(id: "ready", state: .readyToComplete))

        #expect(creating.providerName == "GitHub")
        #expect(creating.providerIconName == "github")
        #expect(creating.issueNumber == "#42")
        #expect(creating.status == .creating("Creating worktree"))
        #expect(running.status == .aggregate("1 working"))
        #expect(needsAttention.status == .aggregate("1 needs attention"))
        #expect(ready.status == .readyToComplete)
    }

    @Test func runningRowUsesAggregateLegStatusCopy() {
        let row = MissionSidebarRow(aggregate: Self.multiLegMission())

        #expect(row.status == .aggregate("1 working · 1 needs attention · 1 ready"))
        #expect(row.tone == .attention)
        #expect(row.helpText.contains("1 working · 1 needs attention · 1 ready"))
    }

    @Test func manualSourceRowDoesNotInventRepositoryOrIssueNumber() {
        let row = MissionSidebarRow(aggregate: MissionFixtures.creatingMission(source: MissionFixtures.manualSource()))

        #expect(row.providerName == "linear.app")
        #expect(row.sourceReference == nil)
        #expect(row.repositorySlug.isEmpty)
        #expect(!row.helpText.contains("#"))
        #expect(!row.helpText.localizedCaseInsensitiveContains("acme/alas"))
    }

    @Test func completedRowStaysMutedWhenALegRetainsAttention() {
        let row = MissionSidebarRow(aggregate: Self.multiLegMission(missionState: .completed))

        #expect(row.status == .completed)
        #expect(row.tone == .muted)
    }

    @Test func creatingMissionNavigatesBeforeAWorktreeIsKnown() {
        let creating = Self.mission(id: "creating", state: .creating, worktreeId: nil)
        let running = Self.mission(id: "running", state: .running, worktreeId: "wt-1")
        let archived = Self.mission(id: "archived", state: .readyToComplete, worktreeId: "archived-wt")

        let rows = MissionSidebarModel.make(
            aggregates: [creating, running, archived],
            activeProjectIds: ["project-1"],
            existingProjectIds: ["project-1"],
            knownWorktreeIds: ["wt-1", "archived-wt"]
        )

        let byID = Dictionary(uniqueKeysWithValues: rows.active.map { ($0.id.rawValue, $0) })
        #expect(byID[creating.mission.id.rawValue]?.isNavigationEnabled == true)
        #expect(byID[running.mission.id.rawValue]?.isNavigationEnabled == true)
        #expect(byID[archived.mission.id.rawValue]?.isNavigationEnabled == true)
    }

    @Test func persistedWorktreeIdStillNavigatesWhenTopologyHasNoMatchingRow() {
        let mission = Self.mission(state: .running, worktreeId: "missing-wt")
        let row = MissionSidebarModel.make(
            aggregates: [mission],
            activeProjectIds: ["project-1"],
            existingProjectIds: ["project-1"],
            knownWorktreeIds: []
        ).active.first

        #expect(row?.isNavigationEnabled == true)
        #expect(row?.helpText.contains("1 working") == true)
    }

    @Test func missingWorktreeAttentionMissionStillNavigatesToRecoveryDetails() {
        let mission = Self.mission(state: .needsAttention, worktreeId: "missing-wt")
        let row = MissionSidebarModel.make(
            aggregates: [mission],
            activeProjectIds: ["project-1"],
            existingProjectIds: ["project-1"],
            knownWorktreeIds: []
        ).active.first

        #expect(row?.isNavigationEnabled == true)
    }

    @Test func completedIdsCoverOnlyTheVisibleCompletedRows() {
        let model = MissionSidebarModel.make(
            aggregates: [
                Self.mission(id: "visible-running", projectId: "alas", state: .running),
                Self.mission(id: "visible-done", projectId: "alas", state: .completed),
                Self.mission(id: "hidden-done", projectId: "other", state: .completed),
            ],
            activeProjectIds: ["alas"],
            existingProjectIds: ["alas", "other"],
            knownWorktreeIds: []
        )

        #expect(model.completedIDs == [MissionID(rawValue: "visible-done")])
        #expect(model.completedIDs.count == model.completed.count)
    }

    @Test func singleDeletionCopyNamesTheMission() {
        let request = MissionDeletionRequest.single(
            id: MissionID(rawValue: "mission-1"),
            title: "Fix parser crash"
        )

        #expect(request.confirmationTitle == "Delete \"Fix parser crash\"?")
        #expect(request.confirmationButtonTitle == "Delete Mission")
        #expect(request.missionIDs == [MissionID(rawValue: "mission-1")])
    }

    @Test func bulkDeletionCopyCountsTheMissions() {
        let one = MissionDeletionRequest.completed([MissionID(rawValue: "a")])
        let many = MissionDeletionRequest.completed([
            MissionID(rawValue: "a"),
            MissionID(rawValue: "b"),
        ])

        #expect(one.confirmationTitle == "Delete 1 completed Mission?")
        #expect(one.confirmationButtonTitle == "Delete 1 Mission")
        #expect(many.confirmationTitle == "Delete 2 completed Missions?")
        #expect(many.confirmationButtonTitle == "Delete 2 Missions")
        #expect(many.missionIDs.map(\.rawValue) == ["a", "b"])
    }

    @Test func deletionConsequenceSpellsOutWhatSurvives() {
        #expect(MissionDeletionRequest.consequence == """
        This removes the Mission and its history from Alas. Worktrees, branches, \
        and running agents are left untouched.
        """)
    }

    private static func mission(
        id: String = "mission-1",
        projectId: String = "project-1",
        state: MissionState = .running,
        updatedAt: TimeInterval = 100,
        worktreeId: String? = "wt-1"
    ) -> MissionAggregate {
        var aggregate = MissionFixtures.creatingMission(id: id)
        aggregate.mission.state = state
        aggregate.mission.setupCheckpoint = state == .creating ? .creatingWorktree : .running
        aggregate.mission.updatedAt = Date(timeIntervalSince1970: updatedAt)
        aggregate.mission.completedAt = state == .completed ? Date(timeIntervalSince1970: updatedAt) : nil
        if state == .needsAttention {
            aggregate.mission.attentionReason = MissionReadinessEvaluator.missingWorktreeMessage
        }
        if var leg = aggregate.primaryLeg {
            leg = .init(
                id: leg.id,
                missionID: leg.missionID,
                ordinal: leg.ordinal,
                projectId: projectId,
                baseRef: leg.baseRef,
                branch: leg.branch,
                destinationPath: leg.destinationPath,
                worktreeId: worktreeId,
                agentId: leg.agentId,
                acpSessionId: leg.acpSessionId,
                initialPromptId: leg.initialPromptId,
                pendingInitialPrompt: leg.pendingInitialPrompt,
                reviewIdentity: leg.reviewIdentity,
                state: Self.legState(for: state),
                setupCheckpoint: state == .creating ? .creatingWorktree : .running,
                attentionReason: state == .needsAttention ? MissionReadinessEvaluator.missingWorktreeMessage : nil,
                readinessEvidence: state == .readyToComplete
                    ? .init(kind: .legacy, observedAt: Date(timeIntervalSince1970: updatedAt))
                    : nil,
                createdAt: leg.createdAt,
                updatedAt: leg.updatedAt
            )
            aggregate.legs = [leg]
        }
        return aggregate
    }

    private static func legState(for missionState: MissionState) -> MissionLegState {
        switch missionState {
        case .creating:
            .creating
        case .running:
            .running
        case .needsAttention:
            .needsAttention
        case .readyToComplete:
            .ready
        case .completed:
            .running
        }
    }

    private static func multiLegMission(missionState: MissionState = .running) -> MissionAggregate {
        let missionID = MissionID(rawValue: "mission-1")
        let appLegID = MissionLegID(rawValue: "mission-1-leg-app")
        let sdkLegID = MissionLegID(rawValue: "mission-1-leg-sdk")
        let serverLegID = MissionLegID(rawValue: "mission-1-leg-server")
        let primary = Self.leg(
            id: appLegID,
            missionID: missionID,
            ordinal: 0,
            projectId: "app",
            state: .running
        )
        return MissionAggregate(
            mission: MissionRecord(
                id: missionID,
                title: "Fix parser crash",
                state: missionState,
                primaryLegID: appLegID,
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 120),
                completedAt: missionState == .completed ? Date(timeIntervalSince1970: 120) : nil
            ),
            source: IssueSnapshot(codeHostIssue: MissionFixtures.issue()),
            legs: [
                primary,
                Self.leg(
                    id: sdkLegID,
                    missionID: missionID,
                    ordinal: 1,
                    projectId: "sdk",
                    state: .needsAttention,
                    attentionReason: "Agent authentication is required."
                ),
                Self.leg(
                    id: serverLegID,
                    missionID: missionID,
                    ordinal: 2,
                    projectId: "server",
                    state: .ready,
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
        state: MissionLegState,
        attentionReason: String? = nil,
        readinessEvidence: MissionLegReadinessEvidence? = nil
    ) -> MissionLeg {
        MissionLeg(
            id: id,
            missionID: missionID,
            ordinal: ordinal,
            projectId: projectId,
            baseRef: "origin/main",
            baseRemoteName: "origin",
            branch: "mission/42-\(projectId)",
            destinationPath: "/tmp/\(projectId)",
            worktreeId: "wt-\(projectId)",
            agentId: "codex",
            acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pendingInitialPrompt: nil,
            reviewIdentity: nil,
            state: state,
            setupCheckpoint: .running,
            attentionReason: attentionReason,
            readinessEvidence: readinessEvidence,
            createdAt: Date(timeIntervalSince1970: 100 + TimeInterval(ordinal)),
            updatedAt: Date(timeIntervalSince1970: 120 + TimeInterval(ordinal))
        )
    }
}
