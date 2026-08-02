import Foundation
import Testing
@testable import Alas

struct MissionSidebarTests {
    @Test func orphanedMissionsKeepTheWorkspaceVisibleWithoutProjects() {
        #expect(RootWorkspaceVisibilityPolicy.showsWorkspace(
            hasProjects: false,
            hasMissions: true
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

    @Test func orphanedMissionRemainsReachableInEverySpace() {
        let mission = Self.mission(projectId: "removed", state: .needsAttention)

        #expect(MissionSpaceFilter.isVisible(
            mission,
            activeProjectIds: ["alas"],
            existingProjectIds: ["alas"]
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
        #expect(running.status == .running)
        #expect(needsAttention.status == .needsAttention)
        #expect(ready.status == .readyToComplete)
    }

    @Test func navigationIsDisabledUntilAWorktreeIsKnown() {
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
        #expect(byID[creating.mission.id.rawValue]?.isNavigationEnabled == false)
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
        #expect(row?.helpText.contains("Running") == true)
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
                reviewIdentity: leg.reviewIdentity
            )
            aggregate.legs = [leg]
        }
        return aggregate
    }
}
