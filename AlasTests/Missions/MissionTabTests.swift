import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct MissionTabTests {
    @Test func missionTabRoundTripsWithStableIdentity() throws {
        let state = MissionTabState(
            missionID: MissionID(rawValue: "mission-1"),
            title: "Fix offline sync conflicts"
        )

        let decoded = try JSONDecoder().decode(
            Tab.self,
            from: JSONEncoder().encode(Tab.mission(state))
        )

        #expect(decoded == .mission(state))
        #expect(decoded.id == "mission:mission-1")
        #expect(decoded.title == "Fix offline sync conflicts")
        #expect(decoded.relativeFilePath == nil)
        #expect(!decoded.supportsSystemOpenActions)
    }

    @Test func rightPaneActivationKeyChangesWhenArchivedVisibilityChanges() {
        let visible = MissionTabContext.rightPaneActivationKey(
            worktreeID: "worktree-1",
            branch: "fix/parser-crash",
            baseRef: "origin/main",
            comparisonMode: "auto",
            worktreeArchived: false
        )
        let archived = MissionTabContext.rightPaneActivationKey(
            worktreeID: "worktree-1",
            branch: "fix/parser-crash",
            baseRef: "origin/main",
            comparisonMode: "auto",
            worktreeArchived: true
        )

        #expect(visible != archived)
    }

    @Test func tabsFileSkipsUnknownCasesWithoutDroppingMissionTabs() throws {
        let mission = Tab.mission(MissionTabState(
            missionID: MissionID(rawValue: "mission-1"),
            title: "Known Mission"
        ))
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(mission)) as? [String: Any]
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "tabs": [encoded, ["futureMission": ["_0": ["id": "future"]]]],
            "activeTabId": mission.id,
        ])

        let decoded = try JSONDecoder().decode(TabsFile.self, from: data)

        #expect(decoded.tabs == [mission])
        #expect(decoded.activeTabId == mission.id)
    }

    @Test func openMissionOpensGlobalTabWithoutSwitchingSpace() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        let tab = try result.get()
        #expect(fixture.state.spacesManager.activeSpaceId == "other-space")
        #expect(fixture.state.selectedWorktreeId == nil)
        #expect(fixture.state.globalTabs.activeTabId == tab.id)
        #expect(fixture.state.globalTabs.activeMissionTab()?.missionID == fixture.aggregate.mission.id)
        #expect(tab == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )))
    }

    @Test func openMissionSelectsArchivedRowWithoutUnarchivingIt() async throws {
        let fixture = try MissionNavigationFixture(hidden: true, includeWorktree: true)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        _ = try result.get()
        #expect(fixture.state.selectedWorktreeId == nil)
        #expect(fixture.state.projectsManager.isWorktreeHidden(
            projectId: "project-1",
            path: fixture.worktree.path
        ))
        #expect(fixture.state.globalTabs.activeTabId == "mission:mission-1")
    }

    @Test func openMissionPresentsDetailWhenNoKnownWorktreeRowExists() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab == MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        ))
        #expect(fixture.state.selectedWorktreeId == nil)
        #expect(fixture.state.globalTabs.activeMissionTab()?.missionID == fixture.aggregate.mission.id)
    }

    @Test func switchingSpacesClearsMissingMissionRecovery() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        #expect(fixture.state.switchToSpace(id: "mission-space"))

        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.selectedWorktreeId == nil)
    }

    @Test func deletingTheActiveSpaceClearsMissingMissionRecovery() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        await fixture.state.missions.load()
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        fixture.state.deleteSpace(id: "mission-space")

        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.selectedWorktreeId == nil)
    }

    @Test func removingTheMissionProjectFromTheActiveSpaceClearsRecovery() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        await fixture.state.missions.load()
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        fixture.state.spacesManager.addProject("project-1", toSpace: "other-space")

        fixture.state.toggleProject(projectId: "project-1", inSpace: "mission-space")

        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.selectedWorktreeId == nil)
    }

    @Test func removingASecondaryMissionProjectFromTheActiveSpaceClearsRecovery() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        await fixture.state.missions.load()
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        fixture.state.selectInitialWorktree(id: secondaryWorktree.id)
        fixture.state.spacesManager.addProject(secondaryWorktree.projectId, toSpace: "other-space")
        fixture.state.projectsManager.removeOptimisticWorktree(
            id: secondaryWorktree.id,
            projectId: secondaryWorktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [secondaryWorktree.id])
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)

        fixture.state.toggleProject(projectId: secondaryWorktree.projectId, inSpace: "mission-space")

        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.selectedWorktreeId == nil)
    }

    @Test func removingAnUnrelatedMissionProjectFromTheActiveSpaceKeepsRecovery() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        await fixture.state.missions.load()
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        fixture.state.selectInitialWorktree(id: secondaryWorktree.id)
        fixture.state.spacesManager.addProject(fixture.worktree.projectId, toSpace: "other-space")
        fixture.state.projectsManager.removeOptimisticWorktree(
            id: secondaryWorktree.id,
            projectId: secondaryWorktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [secondaryWorktree.id])
        let missingSecondaryTab = try #require(fixture.state.missingMissionTab)

        fixture.state.toggleProject(projectId: fixture.worktree.projectId, inSpace: "mission-space")

        #expect(fixture.state.missingMissionTab == missingSecondaryTab)
        #expect(fixture.state.globalTabs.activeMissionTab() == missingSecondaryTab)
    }

    @Test func removingAnotherMissingMissionProjectFromTheActiveSpaceKeepsCurrentRecovery() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        await fixture.state.missions.load()
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        fixture.state.selectInitialWorktree(id: fixture.worktree.id)
        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [fixture.worktree.id])
        let primaryMissingTab = try #require(fixture.state.missingMissionTab)
        await fixture.state.missions.recordMissingWorktree(
            fixture.aggregate.mission.id,
            legID: fixture.aggregate.legs[1].id
        )
        fixture.state.spacesManager.addProject(secondaryWorktree.projectId, toSpace: "other-space")

        fixture.state.toggleProject(projectId: secondaryWorktree.projectId, inSpace: "mission-space")

        #expect(fixture.state.missingMissionTab == primaryMissingTab)
        #expect(fixture.state.globalTabs.activeMissionTab() == primaryMissingTab)
    }

    @Test func activatingAWorktreeTabClearsMissingMissionRecovery() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        await fixture.state.missions.load()
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        fixture.state.selectInitialWorktree(id: secondaryWorktree.id)
        fixture.state.projectsManager.removeOptimisticWorktree(
            id: secondaryWorktree.id,
            projectId: secondaryWorktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [secondaryWorktree.id])
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        fixture.state.selectInitialWorktree(id: fixture.worktree.id)
        let terminal = fixture.state.tabs.appendTerminal(
            worktreeId: fixture.worktree.id,
            title: "Terminal",
            sessionId: "session-1"
        )

        #expect(fixture.state.activateCenterTabNumber(2, worktreeId: fixture.worktree.id) == terminal.id)

        #expect(fixture.state.globalTabs.activeMissionTab() == nil)
        #expect(fixture.state.missingMissionTab == nil)
    }

    @Test func openMissionPresentsRecoveryForAFailedOptimisticWorktree() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        fixture.state.projectsManager.setOperationState(
            id: fixture.worktree.id,
            state: .createFailed(
                projectId: fixture.worktree.projectId,
                message: "branch exists",
                base: "origin/main",
                ggWorktreeMode: .off
            )
        )
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.tabs.activeTab(forWorktree: fixture.worktree.id) == nil)
    }

    @Test func completedMissionDoesNotBindToAWorktreeOwnedByAnotherActiveMission() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            missionState: .completed,
            competingMissionState: .running,
            competingMissionBranch: "replacement-branch"
        )
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.tabs.activeTab(forWorktree: fixture.worktree.id) == nil)
        #expect(fixture.state.missionWorktree(fixture.worktree, for: fixture.aggregate) == nil)
    }

    @Test func completedMissionDoesNotBindToAWorktreeOwnedByALaterCompletedMission() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            missionState: .completed,
            competingMissionState: .completed
        )
        await fixture.state.missions.load()

        #expect(fixture.state.missionWorktree(fixture.worktree, for: fixture.aggregate) == nil)
    }

    @Test func completedMissionDoesNotBindToAWorktreeRecreatedAfterCompletion() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            worktreeLineageID: "replacement",
            missionState: .completed,
            persistedWorktreeLineageID: "original"
        )
        await fixture.state.missions.load()

        #expect(fixture.state.missionWorktree(fixture.worktree, for: fixture.aggregate) == nil)
    }

    @Test func completedMissionBindsUsingStableLineageAcrossTimestampChanges() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            worktreeCreatedAt: 200,
            missionState: .completed,
            persistedWorktreeLineageID: "device:inode"
        )
        await fixture.state.missions.load()

        #expect(fixture.state.missionWorktree(fixture.worktree, for: fixture.aggregate) == fixture.worktree)
    }

    @Test func openMissionPresentsRecoveryForAReplacementBranch() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            worktreeBranch: "unrelated-branch"
        )
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.tabs.activeTab(forWorktree: fixture.worktree.id) == nil)
    }

    @Test func openMissionChangesUsesThePersistedMissionBase() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        let pane = fixture.state.rightPaneStore.state(
            for: fixture.worktree,
            baseBranch: "global-main",
            comparisonMode: fixture.state.config.changes.comparisonMode
        )
        #expect(pane.baseBranch == "global-main")

        await fixture.state.openMissionChanges(
            worktree: fixture.worktree,
            missionID: fixture.aggregate.mission.id,
            legID: try #require(fixture.aggregate.primaryLeg?.id)
        )

        #expect(pane.baseBranch == fixture.aggregate.primaryLeg?.baseRef)
    }

    @Test func openMissionChangesRoutesSecondaryLegToItsPersistedBase() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondary = try #require(fixture.secondaryWorktree)
        let secondaryLeg = try #require(fixture.aggregate.legs.first { $0.projectId == "project-2" })
        await fixture.state.missions.load()
        let pane = fixture.state.rightPaneStore.state(
            for: secondary,
            baseBranch: "global-main",
            comparisonMode: fixture.state.config.changes.comparisonMode
        )
        #expect(pane.baseBranch == "global-main")

        await fixture.state.openMissionChanges(
            worktree: secondary,
            missionID: fixture.aggregate.mission.id,
            legID: secondaryLeg.id
        )

        #expect(pane.baseBranch == secondaryLeg.baseRef)
        #expect(fixture.state.selectedWorktreeId == secondary.id)
    }

    @Test func leavingMissionRestoresTheDefaultRightPaneBase() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        await fixture.state.openMissionChanges(
            worktree: fixture.worktree,
            missionID: fixture.aggregate.mission.id,
            legID: try #require(fixture.aggregate.primaryLeg?.id)
        )
        fixture.state.config.worktrees.baseBranch = "global-main"
        let missionBase = try #require(fixture.aggregate.primaryLeg?.baseRef)
        let pane = fixture.state.rightPaneStore.state(
            for: fixture.worktree,
            baseBranch: missionBase,
            comparisonMode: fixture.state.config.changes.comparisonMode
        )

        fixture.state.restoreDefaultRightPaneBaseAfterMission(worktree: fixture.worktree)

        #expect(pane.reviewLoop.currentBaseBranch == "global-main")
    }

    @Test func leavingMissionRestoresDefaultWhenResolvedBaseDiffersFromPersistedBase() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        await fixture.state.openMissionChanges(
            worktree: fixture.worktree,
            missionID: fixture.aggregate.mission.id,
            legID: try #require(fixture.aggregate.primaryLeg?.id)
        )
        fixture.state.config.worktrees.baseBranch = "origin/main"
        let pane = fixture.state.rightPaneStore.state(
            for: fixture.worktree,
            baseBranch: "upstream/main",
            comparisonMode: fixture.state.config.changes.comparisonMode
        )

        fixture.state.restoreDefaultRightPaneBaseAfterMission(worktree: fixture.worktree)

        #expect(pane.reviewLoop.currentBaseBranch == "origin/main")
    }

    @Test func openMissionPresentsDetailWhenProjectHasBeenRemoved() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeProject: false, includeWorktree: false)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.selectedWorktreeId == nil)
        #expect(fixture.state.globalTabs.activeMissionTab()?.missionID == fixture.aggregate.mission.id)
    }

    @Test func selectedMissionRetainsMissingWorktreeRecoveryPresentation() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [fixture.worktree.id])

        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.selectedWorktreeId == nil)
        #expect(fixture.state.globalTabs.activeMissionTab()?.missionID == fixture.aggregate.mission.id)
        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        let primaryLeg = try #require(aggregate.primaryLeg)
        #expect(primaryLeg.state == .needsAttention)
        #expect(primaryLeg.setupCheckpoint == .running)
        #expect(primaryLeg.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        let presentation = MissionLegPresentation(
            aggregate: aggregate,
            leg: primaryLeg,
            worktree: nil,
            worktreeRecoveryAvailable: true
        )
        #expect(presentation.actions.recoverWorktree)
    }

    @Test func topologyCleanupDetectsAReplacementBranchAtTheSameWorktreeID() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        let beforeIds: Set<String> = [fixture.worktree.id]

        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )
        fixture.state.projectsManager.insertOptimisticWorktree(Worktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId,
            name: "unrelated-branch",
            branch: "unrelated-branch",
            path: fixture.worktree.path,
            status: .clean,
            lastActivity: fixture.worktree.lastActivity
        ))

        await fixture.state.cleanupMissingWorktrees(beforeIds: beforeIds)

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func topologyCleanupDetectsAReplacementLineageOnTheSameBranch() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        let beforeIds: Set<String> = [fixture.worktree.id]

        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )
        var replacement = fixture.worktree
        replacement.lineageID = "replacement-lineage"
        fixture.state.projectsManager.insertOptimisticWorktree(replacement)

        await fixture.state.cleanupMissingWorktrees(beforeIds: beforeIds)

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func topologyCleanupReconcilesMissingMissionAfterDiscoveryRecovers() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )

        await fixture.state.cleanupMissingWorktrees(beforeIds: [])

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func topologyCleanupReconcilesMissingMissionFromALaterCheckpoint() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: false,
            missionState: .needsAttention,
            setupCheckpoint: .startingAgent,
            attentionReason: "ACP setup failed."
        )
        await fixture.state.missions.load()

        await fixture.state.cleanupMissingWorktrees(beforeIds: [])

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.setupCheckpoint == .running)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func topologyCleanupPreservesAnInitialWorktreeCreationFailure() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: false,
            missionState: .needsAttention,
            setupCheckpoint: .creatingWorktree,
            attentionReason: "Git rejected the branch."
        )
        await fixture.state.missions.load()

        await fixture.state.cleanupMissingWorktrees(beforeIds: [])

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.setupCheckpoint == .creatingWorktree)
        #expect(aggregate.primaryLeg?.attentionReason == "Git rejected the branch.")
    }

    @Test func directDeletionMarksTheMissionWorktreeMissing() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()

        await fixture.state.reconcileDeletedMissionWorktree(fixture.worktree.id)

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func directDeletionMarksOnlyTheDeletedSecondaryLegMissing() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        let secondaryLeg = try #require(fixture.aggregate.legs.first { $0.projectId == "project-2" })
        await fixture.state.missions.load()

        await fixture.state.reconcileDeletedMissionWorktree(secondaryWorktree.id)

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.primaryLeg?.state == .running)
        #expect(aggregate.legs.first { $0.id == secondaryLeg.id }?.state == .needsAttention)
        #expect(aggregate.legs.first { $0.id == secondaryLeg.id }?.attentionReason
            == MissionReadinessEvaluator.missingWorktreeMessage)
    }

    @Test func topologyCleanupRestoresAReappearedMissionWorktree() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()

        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [fixture.worktree.id])
        fixture.state.projectsManager.insertOptimisticWorktree(fixture.worktree)

        await fixture.state.cleanupMissingWorktrees(beforeIds: [])

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        let primaryLeg = try #require(aggregate.primaryLeg)
        #expect(primaryLeg.state == .running || primaryLeg.setupCheckpoint == .startingAgent)
        #expect(primaryLeg.attentionReason != MissionReadinessEvaluator.missingWorktreeMessage)
        #expect(fixture.state.missingMissionTab == nil)
    }

    @Test func topologyCleanupRestoresAReappearedSecondaryMissionWorktree() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        let secondaryLeg = try #require(fixture.aggregate.legs.first { $0.projectId == "project-2" })
        await fixture.state.missions.load()
        fixture.state.projectsManager.removeOptimisticWorktree(
            id: secondaryWorktree.id,
            projectId: secondaryWorktree.projectId
        )

        await fixture.state.cleanupMissingWorktrees(beforeIds: [secondaryWorktree.id])

        var aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.legs.first { $0.id == secondaryLeg.id }?.state == .needsAttention)
        fixture.state.projectsManager.insertOptimisticWorktree(secondaryWorktree)

        await fixture.state.cleanupMissingWorktrees(beforeIds: [])

        aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        let restoredSecondaryLeg = try #require(aggregate.legs.first { $0.id == secondaryLeg.id })
        #expect(restoredSecondaryLeg.state == .running || restoredSecondaryLeg.setupCheckpoint == .startingAgent)
        #expect(restoredSecondaryLeg.attentionReason != MissionReadinessEvaluator.missingWorktreeMessage)
        #expect(aggregate.primaryLeg?.state == .running)
    }

    @Test func restoringSecondaryLegKeepsPrimaryMissingRecoveryVisible() async throws {
        let fixture = try MissionNavigationFixture(
            hidden: false,
            includeWorktree: true,
            includeSecondaryLeg: true
        )
        let secondaryWorktree = try #require(fixture.secondaryWorktree)
        await fixture.state.missions.load()

        fixture.state.projectsManager.removeOptimisticWorktree(
            id: fixture.worktree.id,
            projectId: fixture.worktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [fixture.worktree.id])
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        let missingPrimaryTab = try #require(fixture.state.missingMissionTab)

        fixture.state.projectsManager.removeOptimisticWorktree(
            id: secondaryWorktree.id,
            projectId: secondaryWorktree.projectId
        )
        await fixture.state.cleanupMissingWorktrees(beforeIds: [secondaryWorktree.id])
        fixture.state.projectsManager.insertOptimisticWorktree(secondaryWorktree)

        await fixture.state.cleanupMissingWorktrees(beforeIds: [])

        #expect(fixture.state.missingMissionTab == missingPrimaryTab)
    }

    @Test func startupMissingMissionCreatesActionableRecoveryTab() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        #expect(fixture.state.switchToSpace(id: "mission-space"))

        await fixture.state.reconcileMissionsForStartup()

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        let primaryLeg = try #require(aggregate.primaryLeg)
        #expect(primaryLeg.state == .needsAttention)
        #expect(primaryLeg.setupCheckpoint == .running)
        #expect(primaryLeg.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        #expect(fixture.state.missingMissionTab == MissionTabState(
            missionID: fixture.aggregate.mission.id,
            title: fixture.aggregate.mission.title
        ))
        #expect(fixture.state.selectedWorktreeId == nil)
        #expect(fixture.state.globalTabs.activeMissionTab()?.missionID == fixture.aggregate.mission.id)
        let presentation = MissionLegPresentation(
            aggregate: aggregate,
            leg: primaryLeg,
            worktree: nil,
            worktreeRecoveryAvailable: true
        )
        #expect(presentation.actions.recoverWorktree)
    }

    @Test func startupDoesNotOpenMissingMissionFromAnInactiveSpace() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)

        await fixture.state.reconcileMissionsForStartup()

        #expect(fixture.state.spacesManager.activeSpaceId == "other-space")
        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.selectedWorktreeId == nil)
    }

    @Test func startupDoesNotOpenRecoveryForACompletedMission() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        #expect(fixture.state.switchToSpace(id: "mission-space"))
        await fixture.state.missions.load()
        await fixture.state.missions.recordMissingWorktree(fixture.aggregate.mission.id)
        await fixture.state.missions.complete(fixture.aggregate.mission.id)

        await fixture.state.reconcileMissionsForStartup()

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.mission.state == .completed)
        #expect(aggregate.primaryLeg?.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        #expect(fixture.state.missingMissionTab == nil)
        #expect(fixture.state.globalTabs.activeMissionTab() == nil)
    }

    @Test func missionDetailRendersStoredHeaderCaptureAndLegFields() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()
        _ = try fixture.state.openMission(id: fixture.aggregate.mission.id).get()
        let view = MissionTabView(
            state: fixture.state,
            worktree: nil,
            tabState: MissionTabState(
                missionID: fixture.aggregate.mission.id,
                title: fixture.aggregate.mission.title
            )
        )
        .environment(\.theme, try ThemeStore().current)
        let host = NSHostingController(rootView: view)

        host.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        host.view.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "mission-header-repository", in: host.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "mission-header-captured-at", in: host.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "mission-leg-base", in: host.view) != nil)
        #expect(subview(withAccessibilityIdentifier: "mission-leg-destination", in: host.view) != nil)
    }

    @Test func controllerOpensExactlyOnceAfterWorktreeSuccessBeforeACPFailure() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-open-checkpoint-\(UUID().uuidString).sqlite")
        let persistence = MissionPersistence(path: databaseURL.path)
        let worktree = Worktree(
            id: "worktree-1",
            projectId: "project-1",
            name: "fix/parser-crash",
            branch: "fix/parser-crash",
            path: URL(fileURLWithPath: "/tmp/alas-mission"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 100),
            lineageID: "device:inode"
        )
        var openedMissionIDs: [MissionID] = []
        var notifications: [MissionAggregate] = []
        var checkpointAtOpen: MissionAggregate?
        var knownWorktree: Worktree?
        var nextID = 0
        let controller = MissionController(
            environment: .init(
                persistence: persistence,
                now: { Date(timeIntervalSince1970: 100) },
                makeID: {
                    nextID += 1
                    return "generated-\(nextID)"
                },
                worktreeAtDestination: { _, _ in knownWorktree },
                createWorktree: { _ in
                    knownWorktree = worktree
                    return .success(worktree)
                },
                startACP: { _, _ in
                    .failure(.init(message: "ACP executable is unavailable."))
                },
                notifyChanged: { notifications.append($0) }
            ),
            openMission: {
                openedMissionIDs.append($0)
                checkpointAtOpen = notifications.last
            }
        )
        let id = try await controller.create(
            MissionDraft(
                issue: MissionFixtures.issue(),
                projectId: "project-1",
                baseRef: "origin/main",
                branch: "fix/parser-crash",
                destinationPath: "/tmp/alas-mission",
                agentId: "codex",
                initialPromptId: UUID(),
                initialPrompt: "Fix the issue."
            ),
            allowDuplicate: false
        )

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if try await persistence.aggregate(id: id)?.mission.state == .needsAttention { break }
            await Task.yield()
        }
        let failed = try #require(try await persistence.aggregate(id: id))

        #expect(openedMissionIDs == [id])
        #expect(checkpointAtOpen?.mission.state == .creating)
        #expect(checkpointAtOpen?.primaryLeg?.setupCheckpoint == .startingAgent)
        #expect(checkpointAtOpen?.primaryLeg?.worktreeId == worktree.id)
        #expect(checkpointAtOpen?.primaryLeg?.acpSessionId == nil)
        #expect(failed.primaryLeg?.worktreeId == worktree.id)
        #expect(failed.primaryLeg?.acpSessionId != nil)
        #expect(failed.primaryLeg?.setupCheckpoint == .startingAgent)
        #expect(failed.primaryLeg?.state == .needsAttention)
    }

    @Test func restartReconciliationDoesNotReopenMissionForReservedSession() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-restart-no-focus-\(UUID().uuidString).sqlite")
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.setupCheckpoint = .startingAgent
        aggregate.legs[0].setupCheckpoint = .startingAgent
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].acpSessionId = "reserved-session"
        let store = try MissionStore(path: databaseURL.path)
        try store.insert(aggregate)
        let persistence = MissionPersistence(path: databaseURL.path)
        let worktree = Worktree(
            id: "worktree-1",
            projectId: "project-1",
            name: "fix/parser-crash",
            branch: "fix/parser-crash",
            path: URL(fileURLWithPath: "/tmp/alas-mission"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 100)
        )
        var openedMissionIDs: [MissionID] = []
        let controller = MissionController(
            environment: .init(
                persistence: persistence,
                now: { Date(timeIntervalSince1970: 100) },
                makeID: { "generated" },
                worktreeAtDestination: { _, _ in worktree },
                createWorktree: { _ in .failure(.init(message: "Unexpected Git")) },
                startACP: { _, _ in .failure(.init(message: "ACP executable is unavailable.")) },
                notifyChanged: { _ in }
            ),
            openMission: { openedMissionIDs.append($0) }
        )

        await controller.load()
        await controller.reconcileInterrupted()
        let failed = try #require(try await persistence.aggregate(id: aggregate.mission.id))

        #expect(openedMissionIDs.isEmpty)
        #expect(failed.primaryLeg?.acpSessionId == "reserved-session")
        #expect(failed.primaryLeg?.state == .needsAttention)
        #expect(failed.primaryLeg?.setupCheckpoint == .startingAgent)
    }
}

@MainActor
private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier {
        return view
    }
    return view.subviews.lazy.compactMap {
        subview(withAccessibilityIdentifier: identifier, in: $0)
    }.first
}

@MainActor
private struct MissionNavigationFixture {
    let aggregate: MissionAggregate
    let worktree: Worktree
    let secondaryWorktree: Worktree?
    let state: AppState

    init(
        hidden: Bool,
        includeProject: Bool = true,
        includeWorktree: Bool,
        includeSecondaryLeg: Bool = false,
        worktreeBranch: String = "fix/parser-crash",
        worktreeCreatedAt: TimeInterval = 100,
        worktreeLineageID: String = "device:inode",
        missionState: MissionState? = nil,
        setupCheckpoint: MissionSetupCheckpoint = .running,
        attentionReason: String? = nil,
        competingMissionState: MissionState? = nil,
        competingMissionBranch: String = "fix/parser-crash",
        persistedWorktreeLineageID: String? = nil
    ) throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-navigation-\(UUID().uuidString).sqlite")
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = missionState ?? (hidden ? .readyToComplete : .running)
        aggregate.mission.completedAt = aggregate.mission.state == .completed
            ? Date(timeIntervalSince1970: 150)
            : nil
        aggregate.mission.setupCheckpoint = setupCheckpoint
        aggregate.mission.attentionReason = attentionReason
        if aggregate.mission.state != .completed {
            aggregate.legs[0].state = switch aggregate.mission.state {
            case .creating: .creating
            case .running: .running
            case .needsAttention: .needsAttention
            case .readyToComplete: .ready
            case .completed: .running
            }
            aggregate.legs[0].readinessEvidence = aggregate.mission.state == .readyToComplete
                ? MissionLegReadinessEvidence(kind: .legacy, observedAt: Date(timeIntervalSince1970: 100))
                : nil
        }
        aggregate.legs[0].setupCheckpoint = setupCheckpoint
        aggregate.legs[0].attentionReason = attentionReason
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].worktreeLineageID = persistedWorktreeLineageID ?? worktreeLineageID
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        var secondaryLeg: MissionLeg?
        var secondaryWorktree: Worktree?
        if includeSecondaryLeg {
            let secondaryLegID = MissionLegID(rawValue: "\(aggregate.mission.id.rawValue)-leg-2")
            secondaryLeg = MissionLeg(
                id: secondaryLegID,
                missionID: aggregate.mission.id,
                ordinal: 1,
                projectId: "project-2",
                baseRef: "upstream/trunk",
                baseRemoteName: "upstream",
                branch: "fix/server-parser-crash",
                destinationPath: "/tmp/alas-server-mission",
                worktreeId: "worktree-2",
                worktreeLineageID: "device:inode-2",
                agentId: "codex",
                acpSessionId: "session-2",
                initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                pendingInitialPrompt: nil,
                reviewIdentity: nil,
                state: .running,
                setupCheckpoint: .running,
                attentionReason: nil,
                readinessEvidence: nil,
                createdAt: Date(timeIntervalSince1970: 101),
                updatedAt: Date(timeIntervalSince1970: 101)
            )
        }
        let persistence = MissionPersistence(path: databaseURL.path)
        let store = try MissionStore(path: databaseURL.path)
        try store.insert(aggregate)
        if let secondaryLeg {
            try store.addLeg(
                secondaryLeg,
                event: MissionFixtures.event(
                    id: "\(aggregate.mission.id.rawValue)-event-leg-2",
                    missionID: aggregate.mission.id,
                    legID: secondaryLeg.id,
                    kind: .legAdded,
                    createdAt: 101
                )
            )
            aggregate.legs.append(secondaryLeg)
        }
        if let competingMissionState {
            var competitor = MissionFixtures.creatingMission(
                id: "mission-2",
                issue: MissionFixtures.issue(number: 43),
                createdAt: 200
            )
            competitor.mission.state = competingMissionState
            competitor.mission.setupCheckpoint = .running
            competitor.mission.completedAt = competingMissionState == .completed
                ? Date(timeIntervalSince1970: 300)
                : nil
            let originalLeg = competitor.legs[0]
            competitor.legs[0] = MissionLeg(
                id: originalLeg.id,
                missionID: originalLeg.missionID,
                ordinal: originalLeg.ordinal,
                projectId: originalLeg.projectId,
                baseRef: originalLeg.baseRef,
                branch: competingMissionBranch,
                destinationPath: originalLeg.destinationPath,
                worktreeId: originalLeg.worktreeId,
                agentId: originalLeg.agentId,
                acpSessionId: originalLeg.acpSessionId,
                initialPromptId: originalLeg.initialPromptId,
                pendingInitialPrompt: originalLeg.pendingInitialPrompt,
                reviewIdentity: originalLeg.reviewIdentity
            )
            competitor.legs[0].worktreeId = "worktree-1"
            competitor.legs[0].acpSessionId = "session-2"
            competitor.legs[0].pendingInitialPrompt = nil
            try store.insert(competitor)
        }

        let worktree = Worktree(
            id: "worktree-1",
            projectId: "project-1",
            name: "fix/parser-crash",
            branch: worktreeBranch,
            path: URL(fileURLWithPath: "/tmp/alas-mission"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: worktreeCreatedAt),
            createdAt: Date(timeIntervalSince1970: worktreeCreatedAt),
            lineageID: worktreeLineageID
        )
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            hiddenWorktreePaths: hidden ? [worktree.path.path] : []
        )
        let secondaryProject = ProjectConfig(
            id: "project-2",
            name: "Alas Server",
            path: "/tmp/alas-server",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        if includeSecondaryLeg {
            secondaryWorktree = Worktree(
                id: "worktree-2",
                projectId: "project-2",
                name: "fix/server-parser-crash",
                branch: "fix/server-parser-crash",
                path: URL(fileURLWithPath: "/tmp/alas-server-mission"),
                status: .clean,
                lastActivity: Date(timeIntervalSince1970: worktreeCreatedAt),
                createdAt: Date(timeIntervalSince1970: worktreeCreatedAt),
                lineageID: "device:inode-2"
            )
        }
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "other-space",
            spaces: [
                SpaceConfig(
                    id: "other-space",
                    name: "Other",
                    emoji: "1",
                    projectIds: ["other-project"],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date(timeIntervalSince1970: 0)
                ),
                SpaceConfig(
                    id: "mission-space",
                    name: "Mission",
                    emoji: "2",
                    projectIds: includeSecondaryLeg ? [project.id, secondaryProject.id] : [project.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
            ]
        )
        let state = AppState(
            store: MissionNavigationStore(
                projectsFile: ProjectsFile(projects: includeProject
                    ? (includeSecondaryLeg ? [project, secondaryProject] : [project])
                    : []),
                spacesFile: spaces
            ),
            missionPersistence: persistence,
            globalTabs: GlobalTabsManager(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mission-global-tabs-\(UUID().uuidString).json")
            )
        )
        if includeWorktree {
            state.projectsManager.insertOptimisticWorktree(worktree)
            if let secondaryWorktree {
                state.projectsManager.insertOptimisticWorktree(secondaryWorktree)
            }
        }

        self.aggregate = aggregate
        self.worktree = worktree
        self.secondaryWorktree = secondaryWorktree
        self.state = state
    }
}

private struct MissionNavigationStore: PersistenceStoreProtocol {
    let projectsFile: ProjectsFile
    let spacesFile: SpacesFile

    func write<T: Encodable>(_ value: T, to url: URL) throws {}

    func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        if type == ProjectsFile.self { return projectsFile as? T }
        if type == SpacesFile.self { return spacesFile as? T }
        if type == AppConfig.self { return AppConfig.defaults as? T }
        return nil
    }
}
