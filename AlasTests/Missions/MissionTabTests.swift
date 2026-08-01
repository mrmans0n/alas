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
            worktreeId: "worktree-1",
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

    @Test func tabsFileSkipsUnknownCasesWithoutDroppingMissionTabs() throws {
        let mission = Tab.mission(MissionTabState(
            missionID: MissionID(rawValue: "mission-1"),
            worktreeId: "worktree-1",
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

    @Test func openMissionSwitchesSpaceAndOpensPrimaryLegTab() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: true)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        let tab = try result.get()
        #expect(fixture.state.spacesManager.activeSpaceId == "mission-space")
        #expect(fixture.state.selectedWorktreeId == "worktree-1")
        #expect(fixture.state.tabs.activeTabId(forWorktree: "worktree-1") == tab.id)
        #expect(tab == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            worktreeId: "worktree-1",
            title: fixture.aggregate.mission.title
        )))
    }

    @Test func openMissionSelectsArchivedRowWithoutUnarchivingIt() async throws {
        let fixture = try MissionNavigationFixture(hidden: true, includeWorktree: true)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        _ = try result.get()
        #expect(fixture.state.selectedWorktreeId == "worktree-1")
        #expect(fixture.state.projectsManager.isWorktreeHidden(
            projectId: "project-1",
            path: fixture.worktree.path
        ))
        #expect(fixture.state.tabs.activeTab(forWorktree: "worktree-1")?.id == "mission:mission-1")
    }

    @Test func openMissionPresentsDetailWhenNoKnownWorktreeRowExists() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            worktreeId: fixture.worktree.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab == MissionTabState(
            missionID: fixture.aggregate.mission.id,
            worktreeId: fixture.worktree.id,
            title: fixture.aggregate.mission.title
        ))
        #expect(fixture.state.selectedWorktreeId == fixture.worktree.id)
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
            worktreeId: fixture.worktree.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.tabs.activeTab(forWorktree: fixture.worktree.id) == nil)
    }

    @Test func openMissionPresentsDetailWhenProjectHasBeenRemoved() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeProject: false, includeWorktree: false)
        await fixture.state.missions.load()

        let result = fixture.state.openMission(id: fixture.aggregate.mission.id)

        #expect(try result.get() == .mission(MissionTabState(
            missionID: fixture.aggregate.mission.id,
            worktreeId: fixture.worktree.id,
            title: fixture.aggregate.mission.title
        )))
        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.selectedWorktreeId == fixture.worktree.id)
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

        #expect(fixture.state.missingMissionTab?.missionID == fixture.aggregate.mission.id)
        #expect(fixture.state.selectedWorktreeId == fixture.worktree.id)
        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.mission.state == .needsAttention)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: nil,
            worktreeRecoveryAvailable: true
        )
        #expect(presentation.worktreeRecovery == .recreateMissing)
        #expect(presentation.actions.recoverWorktree)
    }

    @Test func startupMissingMissionCreatesActionableRecoveryTab() async throws {
        let fixture = try MissionNavigationFixture(hidden: false, includeWorktree: false)

        await fixture.state.reconcileMissionsForStartup()

        let aggregate = try #require(fixture.state.missions.aggregate(id: fixture.aggregate.mission.id))
        #expect(aggregate.mission.state == .needsAttention)
        #expect(aggregate.mission.setupCheckpoint == .running)
        #expect(aggregate.mission.attentionReason == MissionReadinessEvaluator.missingWorktreeMessage)
        #expect(fixture.state.missingMissionTab == MissionTabState(
            missionID: fixture.aggregate.mission.id,
            worktreeId: fixture.worktree.id,
            title: fixture.aggregate.mission.title
        ))
        #expect(fixture.state.selectedWorktreeId == fixture.worktree.id)
        let presentation = MissionTabPresentation(
            aggregate: aggregate,
            worktree: nil,
            worktreeRecoveryAvailable: true
        )
        #expect(presentation.worktreeRecovery == .recreateMissing)
        #expect(presentation.actions.recoverWorktree)
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
                worktreeId: fixture.worktree.id,
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
            lastActivity: Date(timeIntervalSince1970: 100)
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
        #expect(checkpointAtOpen?.mission.setupCheckpoint == .startingAgent)
        #expect(checkpointAtOpen?.primaryLeg?.worktreeId == worktree.id)
        #expect(checkpointAtOpen?.primaryLeg?.acpSessionId == nil)
        #expect(failed.primaryLeg?.worktreeId == worktree.id)
        #expect(failed.primaryLeg?.acpSessionId != nil)
        #expect(failed.mission.setupCheckpoint == .startingAgent)
        #expect(failed.mission.state == .needsAttention)
    }

    @Test func restartReconciliationDoesNotReopenMissionForReservedSession() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-restart-no-focus-\(UUID().uuidString).sqlite")
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.setupCheckpoint = .startingAgent
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
        #expect(failed.mission.state == .needsAttention)
        #expect(failed.mission.setupCheckpoint == .startingAgent)
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
    let state: AppState

    init(
        hidden: Bool,
        includeProject: Bool = true,
        includeWorktree: Bool,
        worktreeBranch: String = "fix/parser-crash"
    ) throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-navigation-\(UUID().uuidString).sqlite")
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = hidden ? .readyToComplete : .running
        aggregate.mission.setupCheckpoint = .running
        aggregate.legs[0].worktreeId = "worktree-1"
        aggregate.legs[0].acpSessionId = "session-1"
        aggregate.legs[0].pendingInitialPrompt = nil
        let persistence = MissionPersistence(path: databaseURL.path)
        let store = try MissionStore(path: databaseURL.path)
        try store.insert(aggregate)

        let worktree = Worktree(
            id: "worktree-1",
            projectId: "project-1",
            name: "fix/parser-crash",
            branch: worktreeBranch,
            path: URL(fileURLWithPath: "/tmp/alas-mission"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 100)
        )
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0),
            hiddenWorktreePaths: hidden ? [worktree.path.path] : []
        )
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
                    projectIds: [project.id],
                    lastSelectedWorktreeId: nil,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
            ]
        )
        let state = AppState(
            store: MissionNavigationStore(
                projectsFile: ProjectsFile(projects: includeProject ? [project] : []),
                spacesFile: spaces
            ),
            missionPersistence: persistence
        )
        if includeWorktree {
            state.projectsManager.insertOptimisticWorktree(worktree)
        }

        self.aggregate = aggregate
        self.worktree = worktree
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
