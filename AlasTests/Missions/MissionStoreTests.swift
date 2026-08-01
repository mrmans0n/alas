import Foundation
import Testing
@testable import Alas

@Suite("Mission store")
struct MissionStoreTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-store-\(UUID().uuidString).sqlite")
            .path
    }

    @Test("creates schema and persists ordered events across reopen")
    func persistsAggregateAndOrderedEventsAcrossReopen() throws {
        let path = temporaryPath()
        let aggregate = MissionFixtures.creatingMission()

        do {
            let store = try MissionStore(path: path)
            #expect(try store.currentSchemaVersion() == MissionStore.targetSchemaVersion)
            try store.insert(aggregate)
            try store.updateSetup(
                id: aggregate.mission.id,
                state: .running,
                checkpoint: .running,
                attentionReason: nil,
                event: MissionFixtures.event(
                    id: "event-2",
                    missionID: aggregate.mission.id,
                    legID: aggregate.primaryLeg!.id,
                    kind: .agentStarted,
                    createdAt: 102
                )
            )
        }

        let reopened = try MissionStore(path: path)
        let loaded = try #require(try reopened.aggregate(id: aggregate.mission.id))
        #expect(loaded.mission.state == .running)
        #expect(loaded.mission.setupCheckpoint == .running)
        #expect(loaded.events.map(\.id) == ["mission-1-event-1", "event-2"])
    }

    @Test("rejects aggregates without exactly one primary leg")
    func validatesExactlyOneLeg() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.legs = []

        #expect(throws: MissionStore.Error.exactlyOneLeg) {
            try store.insert(aggregate)
        }
    }

    @Test("rejects a second active mission for the same issue identity")
    func rejectsDuplicateActiveIssueIdentity() throws {
        let store = try MissionStore(path: temporaryPath())
        try store.insert(MissionFixtures.creatingMission(id: "mission-1"))

        #expect(throws: MissionStore.Error.duplicateActiveIssueIdentity) {
            try store.insert(MissionFixtures.creatingMission(id: "mission-2"))
        }
    }

    @Test("completed mission does not block reuse of its issue identity")
    func completedMissionDoesNotBlockSameIssueIdentity() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission(id: "mission-1")
        try store.insert(aggregate)
        try store.complete(
            id: aggregate.mission.id,
            at: Date(timeIntervalSince1970: 200),
            event: MissionFixtures.event(
                id: "completed",
                missionID: aggregate.mission.id,
                kind: .completed,
                createdAt: 200
            )
        )

        #expect(try store.activeMission(issueIdentity: aggregate.issue.identity) == nil)
        try store.insert(MissionFixtures.creatingMission(id: "mission-2"))
        #expect(try store.activeMission(issueIdentity: aggregate.issue.identity)?.mission.id == MissionID(rawValue: "mission-2"))
    }

    @Test("setup state and its event are committed together")
    func updatesSetupStateAndEventAtomically() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        try store.updateSetup(
            id: aggregate.mission.id,
            state: .needsAttention,
            checkpoint: .startingAgent,
            attentionReason: "Agent authentication is required.",
            event: MissionFixtures.event(
                id: "attention",
                missionID: aggregate.mission.id,
                kind: .attentionRequired,
                createdAt: 120
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.mission.state == .needsAttention)
        #expect(loaded.mission.attentionReason == "Agent authentication is required.")
        #expect(loaded.events.last?.id == "attention")
    }

    @Test("replaces a refreshed issue snapshot and records the refresh")
    func replacesIssueSnapshot() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        let refreshed = MissionFixtures.issue(
            title: "Fix parser crash in YAML files",
            labels: ["bug", "high-priority"],
            capturedAt: 150
        )
        try store.replaceIssueSnapshot(
            missionID: aggregate.mission.id,
            snapshot: refreshed,
            event: MissionFixtures.event(
                id: "refreshed",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.issue == refreshed)
        #expect(loaded.events.last?.kind == .sourceRefreshed)
    }

    @Test("refresh-error write keeps a success committed after the failure read")
    func refreshErrorUpdateDoesNotReplaceNewerSnapshot() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)

        // Model the former controller interleaving: a failing refresh has read
        // this snapshot when a concurrent successful refresh commits first.
        let stale = try #require(try store.aggregate(id: aggregate.mission.id))
        let refreshed = MissionFixtures.issue(
            title: "Success committed after the failure read",
            capturedAt: 200
        )
        try store.replaceIssueSnapshot(
            missionID: aggregate.mission.id,
            snapshot: refreshed,
            event: MissionFixtures.event(
                id: "success-after-read",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 200
            )
        )
        try store.updateIssueRefreshError(
            missionID: aggregate.mission.id,
            refreshError: "Authentication is required for github.com.",
            event: MissionFixtures.event(
                id: "failure-after-success",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 201
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(stale.issue.title != refreshed.title)
        #expect(loaded.issue.title == refreshed.title)
        #expect(loaded.issue.capturedAt == refreshed.capturedAt)
        #expect(loaded.issue.refreshError == "Authentication is required for github.com.")
    }

    @Test("rejects a refreshed snapshot that changes the mission issue identity")
    func rejectsIssueIdentityChangeDuringRefresh() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        let changedIdentity = MissionFixtures.issue(number: 43, capturedAt: 150)

        #expect(throws: (any Error).self) {
            try store.replaceIssueSnapshot(
                missionID: aggregate.mission.id,
                snapshot: changedIdentity,
                event: MissionFixtures.event(
                    id: "wrong-identity-refresh",
                    missionID: aggregate.mission.id,
                    kind: .sourceRefreshed,
                    createdAt: 150
                )
            )
        }

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.issue == aggregate.issue)
        #expect(loaded.events.map(\.id) == ["mission-1-event-1"])
    }

    @Test("lists active missions before completed missions")
    func ordersActiveMissionsBeforeCompletedMissions() throws {
        let store = try MissionStore(path: temporaryPath())
        let completed = MissionFixtures.creatingMission(id: "completed", issue: MissionFixtures.issue(number: 1), createdAt: 100)
        let olderActive = MissionFixtures.creatingMission(id: "older-active", issue: MissionFixtures.issue(number: 2), createdAt: 200)
        let newerActive = MissionFixtures.creatingMission(id: "newer-active", issue: MissionFixtures.issue(number: 3), createdAt: 300)
        try store.insert(completed)
        try store.insert(olderActive)
        try store.insert(newerActive)
        try store.complete(
            id: completed.mission.id,
            at: Date(timeIntervalSince1970: 400),
            event: MissionFixtures.event(id: "completed-event", missionID: completed.mission.id, kind: .completed, createdAt: 400)
        )

        #expect(try store.list(includeCompleted: true).map(\.mission.id) == [
            MissionID(rawValue: "newer-active"),
            MissionID(rawValue: "older-active"),
            MissionID(rawValue: "completed"),
        ])
        #expect(try store.list(includeCompleted: false).map(\.mission.id) == [
            MissionID(rawValue: "newer-active"),
            MissionID(rawValue: "older-active"),
        ])
    }
}
