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

    @Test("migrates v1 base refs without guessing their remote identity")
    func migratesLegacyBaseRefWithoutGuessingRemoteIdentity() throws {
        let path = temporaryPath()
        let v1 = try SQLiteDatabase(path: path)
        try v1.exec("CREATE TABLE schema_version (version INTEGER NOT NULL)")
        try v1.exec("INSERT INTO schema_version (version) VALUES (1)")
        try v1.exec("CREATE TABLE mission_legs (id TEXT PRIMARY KEY, base_ref TEXT NOT NULL)")
        try v1.exec("INSERT INTO mission_legs (id, base_ref) VALUES ('leg-1', 'upstream/main')")

        let migrated = try MissionStore(path: path)
        let row = try #require(try migrated.db.query(
            "SELECT base_remote_name, worktree_lineage_id FROM mission_legs WHERE id = 'leg-1'"
        ).first)

        #expect(try migrated.currentSchemaVersion() == MissionStore.targetSchemaVersion)
        #expect(row["base_remote_name"] as? String == nil)
        #expect(row["worktree_lineage_id"] as? String == nil)
    }

    @Test("rolls back schema changes when the version update fails")
    func migrationSchemaAndVersionAreAtomic() throws {
        let path = temporaryPath()
        let v1 = try SQLiteDatabase(path: path)
        try v1.exec("CREATE TABLE schema_version (version INTEGER NOT NULL CHECK(version = 1))")
        try v1.exec("INSERT INTO schema_version (version) VALUES (1)")
        try v1.exec("CREATE TABLE mission_legs (id TEXT PRIMARY KEY, base_ref TEXT NOT NULL)")

        #expect(throws: (any Error).self) {
            _ = try MissionStore(path: path)
        }

        let columns = try v1.query("PRAGMA table_info(mission_legs)")
            .compactMap { $0["name"] as? String }
        #expect(!columns.contains("base_remote_name"))
        #expect(!columns.contains("worktree_lineage_id"))
        #expect(try v1.query("SELECT version FROM schema_version").first?["version"] as? Int64 == 1)
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
        #expect(loaded.primaryLeg?.baseRemoteName == "origin")
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

    @Test("rejects a duplicate issue identity with different repository casing")
    func rejectsDuplicateIssueIdentityIgnoringRepositoryCase() throws {
        let store = try MissionStore(path: temporaryPath())
        try store.insert(MissionFixtures.creatingMission(id: "mission-1"))
        let issue = MissionFixtures.issue()
        let differentlyCasedIssue = MissionIssueSnapshot(
            identity: .init(
                provider: issue.identity.provider,
                host: "GitHub.com",
                repositorySlug: "Acme/Alas",
                number: issue.identity.number
            ),
            canonicalURL: issue.canonicalURL,
            title: issue.title,
            body: issue.body,
            state: issue.state,
            labels: issue.labels,
            assignees: issue.assignees,
            providerUpdatedAt: issue.providerUpdatedAt,
            capturedAt: issue.capturedAt,
            refreshError: issue.refreshError
        )

        #expect(throws: MissionStore.Error.duplicateActiveIssueIdentity) {
            try store.insert(MissionFixtures.creatingMission(id: "mission-2", issue: differentlyCasedIssue))
        }
    }

    @Test("completed mission does not block reuse of its issue identity")
    func completedMissionDoesNotBlockSameIssueIdentity() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission(id: "mission-1")
        try store.insert(aggregate)
        var leg = try #require(aggregate.primaryLeg)
        leg.worktreeLineageID = "device:inode"
        try store.complete(
            id: aggregate.mission.id,
            leg: leg,
            at: Date(timeIntervalSince1970: 200),
            event: MissionFixtures.event(
                id: "completed",
                missionID: aggregate.mission.id,
                kind: .completed,
                createdAt: 200
            )
        )

        #expect(try store.activeMission(issueIdentity: aggregate.issue.identity) == nil)
        #expect(try store.aggregate(id: aggregate.mission.id)?.primaryLeg?.worktreeLineageID == "device:inode")
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

    @Test("leg events advance mission activity time")
    func legEventsAdvanceMissionActivityTime() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        var leg = try #require(aggregate.primaryLeg)
        leg.reviewIdentity = MissionReviewIdentity(
            provider: .github,
            host: "github.com",
            repositorySlug: "acme/alas",
            number: 91,
            url: URL(string: "https://github.com/acme/alas/pull/91")!
        )

        try store.updateLeg(
            leg,
            event: MissionFixtures.event(
                id: "review-linked",
                missionID: aggregate.mission.id,
                legID: leg.id,
                kind: .reviewLinked,
                createdAt: 200
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.mission.updatedAt == Date(timeIntervalSince1970: 200))
        #expect(loaded.events.last?.id == "review-linked")
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
        #expect(loaded.mission.title == refreshed.title)
        #expect(loaded.events.last?.kind == .sourceRefreshed)
    }

    @Test("refreshes through repository casing changes while preserving the stored identity")
    func refreshPreservesIdentityAcrossRepositoryCasingChanges() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        let issue = MissionFixtures.issue(title: "Fresh title", capturedAt: 150)
        let differentlyCasedIssue = MissionIssueSnapshot(
            identity: .init(
                provider: issue.identity.provider,
                host: "GitHub.com",
                repositorySlug: "Acme/Alas",
                number: issue.identity.number
            ),
            canonicalURL: issue.canonicalURL,
            title: issue.title,
            body: issue.body,
            state: issue.state,
            labels: issue.labels,
            assignees: issue.assignees,
            providerUpdatedAt: issue.providerUpdatedAt,
            capturedAt: issue.capturedAt,
            refreshError: issue.refreshError
        )

        try store.replaceIssueSnapshot(
            missionID: aggregate.mission.id,
            snapshot: differentlyCasedIssue,
            event: MissionFixtures.event(
                id: "casing-refresh",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.issue.identity == aggregate.issue.identity)
        #expect(loaded.issue.title == "Fresh title")
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

    @Test("migrates a provider-confirmed repository rename and its linked review")
    func migratesRepositoryRenameDuringRefresh() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.legs[0].reviewIdentity = MissionReviewIdentity(
            provider: aggregate.issue.identity.provider,
            host: aggregate.issue.identity.host,
            repositorySlug: aggregate.issue.identity.repositorySlug,
            number: 17,
            url: URL(string: "https://github.com/acme/alas/pull/17")!
        )
        try store.insert(aggregate)
        let renamed = MissionIssueSnapshot(
            identity: .init(
                provider: aggregate.issue.identity.provider,
                host: aggregate.issue.identity.host,
                repositorySlug: "acquired/renamed-alas",
                number: aggregate.issue.identity.number
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            title: "Fresh after rename",
            body: aggregate.issue.body,
            state: aggregate.issue.state,
            labels: aggregate.issue.labels,
            assignees: aggregate.issue.assignees,
            providerUpdatedAt: aggregate.issue.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 150),
            refreshError: nil
        )

        try store.replaceIssueSnapshot(
            missionID: aggregate.mission.id,
            snapshot: renamed,
            event: MissionFixtures.event(
                id: "rename-refresh",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.issue.identity == renamed.identity)
        #expect(loaded.primaryLeg?.reviewIdentity?.repositorySlug == "acquired/renamed-alas")
        #expect(loaded.primaryLeg?.reviewIdentity?.number == 17)
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
