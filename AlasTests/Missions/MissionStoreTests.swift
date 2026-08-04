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

    @Test("v5 issue rows migrate to provider-neutral sources")
    func migratesV5IssueRowsToProviderNeutralSources() throws {
        let path = temporaryPath()
        do { _ = try MissionStoreTestDatabase.v5(path: URL(fileURLWithPath: path)) }

        let store = try MissionStore(path: path)
        let aggregate = try #require(try store.aggregate(id: .init(rawValue: "mission-1")))
        let tableNames = try store.db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        ).compactMap { $0["name"] as? String }
        let missionColumns = try store.db.query("PRAGMA table_info(missions)")
            .compactMap { $0["name"] as? String }

        #expect(try store.currentSchemaVersion() == 6)
        #expect(aggregate.source.identity == .init(
            providerID: .github,
            stableID: "github.com/acme/alas#42"
        ))
        #expect(aggregate.source.repositoryLocator?.repositorySlug == "acme/alas")
        #expect(aggregate.source.displayReference == "#42")
        #expect(!missionColumns.contains("source_kind"))
        #expect(tableNames.contains("mission_sources"))
        #expect(!tableNames.contains("mission_issue_sources"))
    }

    @Test("v5 source migration rolls back all schema and data changes")
    func malformedV5SourceMigrationRollsBack() throws {
        let path = temporaryPath()
        let v5 = try MissionStoreTestDatabase.v5(
            path: URL(fileURLWithPath: path),
            provider: "unsupported"
        )

        #expect(throws: MissionStore.Error.malformedRecord) {
            _ = try MissionStore(path: path)
        }

        let tableNames = try v5.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0["name"] as? String }
        #expect(try v5.query("SELECT version FROM schema_version").first?["version"] as? Int64 == 5)
        #expect(try v5.query("SELECT provider FROM mission_issue_sources").first?["provider"] as? String == "unsupported")
        #expect(tableNames.contains("missions"))
        #expect(tableNames.contains("mission_issue_sources"))
        #expect(!tableNames.contains("mission_sources"))
        #expect(!tableNames.contains("missions_v5"))
    }

    @Test("v6 migration rejects a v5 database without the required Mission tables")
    func missingV5TablesMigrationRollsBack() throws {
        let path = temporaryPath()
        let v5 = try SQLiteDatabase(path: path)
        try v5.exec("CREATE TABLE schema_version (version INTEGER NOT NULL)")
        try v5.exec("INSERT INTO schema_version (version) VALUES (5)")

        #expect(throws: MissionStore.Error.malformedRecord) {
            _ = try MissionStore(path: path)
        }

        #expect(try v5.query("SELECT version FROM schema_version").first?["version"] as? Int64 == 5)
        let tableNames = try v5.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0["name"] as? String }
        #expect(Set(tableNames) == Set(["schema_version"]))
    }

    @Test("v6 migration rejects an event whose leg does not belong to its Mission")
    func invalidV5EventLegMigrationRollsBack() throws {
        let path = temporaryPath()
        let v5 = try MissionStoreTestDatabase.v5(path: URL(fileURLWithPath: path))
        try v5.exec("UPDATE mission_events SET leg_id = 'missing-leg' WHERE id = 'event-1'")

        #expect(throws: MissionStore.Error.malformedRecord) {
            _ = try MissionStore(path: path)
        }

        #expect(try v5.query("SELECT version FROM schema_version").first?["version"] as? Int64 == 5)
        #expect(try v5.query("SELECT leg_id FROM mission_events WHERE id = 'event-1'").first?["leg_id"] as? String == "missing-leg")
        let tableNames = try v5.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0["name"] as? String }
        #expect(tableNames.contains("missions"))
        #expect(tableNames.contains("mission_events"))
        #expect(!tableNames.contains("missions_v5"))
    }

    @Test("manual sources round trip and reject an active duplicate")
    func manualSourceRoundTripsAndRejectsAnActiveDuplicate() throws {
        let store = try MissionStore(path: temporaryPath())
        let first = MissionFixtures.creatingMission(source: MissionFixtures.manualSource())
        let second = MissionFixtures.creatingMission(id: "mission-2", source: first.source)

        try store.insert(first)
        #expect(throws: MissionStore.Error.duplicateActiveSourceIdentity) {
            try store.insert(second)
        }
        #expect(try store.aggregate(id: first.mission.id)?.source == first.source)
        #expect(try store.activeMission(sourceIdentity: first.source.identity)?.mission.id == first.mission.id)
    }

    @Test("provider-neutral refresh replaces content and preserves an unchanged identity")
    func replacesSourceSnapshot() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        let refreshed = MissionSourceSnapshot(issue: MissionFixtures.issue(
            title: "Fix parser crash in YAML files",
            capturedAt: 150
        ))

        let migrated = try store.replaceSourceSnapshot(
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
        #expect(migrated == [aggregate.mission.id])
        #expect(loaded.source == refreshed)
        #expect(loaded.mission.title == refreshed.title)
        #expect(loaded.events.last?.kind == .sourceRefreshed)
    }

    @Test("manual sources cannot be replaced through the refresh API")
    func rejectsManualSourceReplacement() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission(source: MissionFixtures.manualSource())
        try store.insert(aggregate)
        let source = aggregate.source
        func replacement(
            canonicalURL: URL? = nil,
            contentOrigin: MissionSourceContentOrigin? = nil,
            isEditable: Bool? = nil,
            isRefreshable: Bool? = nil
        ) -> MissionSourceSnapshot {
            MissionSourceSnapshot(
                identity: source.identity,
                canonicalURL: canonicalURL ?? source.canonicalURL,
                providerLabel: source.providerLabel,
                displayReference: source.displayReference,
                repositoryLocator: source.repositoryLocator,
                title: "Replacement title",
                body: "Replacement body",
                state: source.state,
                labels: source.labels,
                assignees: source.assignees,
                providerUpdatedAt: source.providerUpdatedAt,
                capturedAt: Date(timeIntervalSince1970: 150),
                refreshError: source.refreshError,
                contentOrigin: contentOrigin ?? source.contentOrigin,
                isEditable: isEditable ?? source.isEditable,
                isRefreshable: isRefreshable ?? source.isRefreshable
            )
        }
        let replacements = [
            replacement(canonicalURL: URL(string: "https://linear.app/acme/issue/ALA-99/other")!),
            replacement(contentOrigin: .provider),
            replacement(isEditable: false),
            replacement(isRefreshable: true),
        ]

        for (index, snapshot) in replacements.enumerated() {
            #expect(throws: MissionStore.Error.sourceNotRefreshable) {
                try store.replaceSourceSnapshot(
                    missionID: aggregate.mission.id,
                    snapshot: snapshot,
                    event: MissionFixtures.event(
                        id: "manual-replacement-\(index)",
                        missionID: aggregate.mission.id,
                        kind: .sourceRefreshed,
                        createdAt: 150 + Double(index)
                    )
                )
            }
            #expect(try store.aggregate(id: aggregate.mission.id)?.source == source)
        }
    }

    @Test("manual source edits preserve identity, URL, and capabilities")
    func updatesManualSourceContent() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission(source: MissionFixtures.manualSource())
        try store.insert(aggregate)

        try store.updateManualSourceContent(
            missionID: aggregate.mission.id,
            title: "Edited title",
            body: "Edited body",
            event: MissionFixtures.event(
                id: "manual-edit",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 175
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.source.identity == aggregate.source.identity)
        #expect(loaded.source.canonicalURL == aggregate.source.canonicalURL)
        #expect(loaded.source.isEditable == aggregate.source.isEditable)
        #expect(loaded.source.isRefreshable == aggregate.source.isRefreshable)
        #expect(loaded.source.title == "Edited title")
        #expect(loaded.source.body == "Edited body")
        #expect(loaded.source.capturedAt == Date(timeIntervalSince1970: 175))
        #expect(loaded.mission.title == "Edited title")
        #expect(loaded.events.last?.kind == .sourceRefreshed)
        #expect(loaded.events.last?.message == "Source context updated.")
    }

    @Test("manual source edits require an editable source")
    func rejectsManualContentUpdateForProviderSource() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)

        #expect(throws: MissionStore.Error.sourceNotEditable) {
            try store.updateManualSourceContent(
                missionID: aggregate.mission.id,
                title: "Edited title",
                body: "Edited body",
                event: MissionFixtures.event(
                    id: "manual-edit",
                    missionID: aggregate.mission.id,
                    kind: .sourceRefreshed,
                    createdAt: 175
                )
            )
        }
        #expect(try store.aggregate(id: aggregate.mission.id)?.source == aggregate.source)
    }

    @Test("v4 migrates legacy Mission attention onto its leg")
    func migratesLegacyAttentionToLeg() throws {
        let path = temporaryPath()
        do {
            _ = try MissionStoreTestDatabase.v3(
                path: URL(fileURLWithPath: path),
                missionState: "needsAttention",
                checkpoint: "startingAgent",
                attentionReason: "Install Codex"
            )
        }

        let store = try MissionStore(path: path)
        let aggregate = try #require(try store.aggregate(id: MissionID(rawValue: "mission-1")))

        #expect(try store.currentSchemaVersion() == MissionStore.targetSchemaVersion)
        #expect(aggregate.mission.state == .running)
        #expect(aggregate.primaryLeg?.state == .needsAttention)
        #expect(aggregate.primaryLeg?.setupCheckpoint == .startingAgent)
        #expect(aggregate.primaryLeg?.attentionReason == "Install Codex")
    }

    @Test("v4 migrates each legacy Mission lifecycle state")
    func migratesLegacyMissionLifecycleStates() throws {
        let cases: [(state: String, checkpoint: String, mission: MissionState, leg: MissionLegState, readiness: MissionLegReadinessKind?)] = [
            ("creating", "creatingWorktree", .creating, .creating, nil),
            ("running", "running", .running, .running, nil),
            ("needsAttention", "startingAgent", .running, .needsAttention, nil),
            ("readyToComplete", "running", .readyToComplete, .ready, .legacy),
            ("completed", "running", .completed, .running, nil),
            ("completed", "creatingWorktree", .completed, .creating, nil),
            ("completed", "startingAgent", .completed, .creating, nil),
        ]

        for (index, legacyCase) in cases.enumerated() {
            let path = temporaryPath()
            do {
                _ = try MissionStoreTestDatabase.v3(
                    path: URL(fileURLWithPath: path),
                    missionState: legacyCase.state,
                    checkpoint: legacyCase.checkpoint,
                    attentionReason: "Legacy reason"
                )
            }

            let store = try MissionStore(path: path)
            let aggregate = try #require(try store.aggregate(id: MissionID(rawValue: "mission-1")))

            #expect(aggregate.mission.state == legacyCase.mission, "case \(index)")
            #expect(aggregate.primaryLeg?.state == legacyCase.leg, "case \(index)")
            #expect(aggregate.primaryLeg?.setupCheckpoint.rawValue == legacyCase.checkpoint, "case \(index)")
            #expect(aggregate.primaryLeg?.attentionReason == "Legacy reason", "case \(index)")
            #expect(aggregate.primaryLeg?.readinessEvidence?.kind == legacyCase.readiness, "case \(index)")
            if legacyCase.readiness != nil {
                #expect(aggregate.primaryLeg?.readinessEvidence?.observedAt == Date(timeIntervalSince1970: 101))
            }
        }
    }

    @Test("rejects multiple legs during initial Mission insertion")
    func rejectsMultipleInitialLegs() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs[0].state = .running
        aggregate.legs[0].setupCheckpoint = .running
        let secondLeg = MissionLeg(
            id: MissionLegID(rawValue: "mission-1-leg-2"),
            missionID: aggregate.mission.id,
            ordinal: 1,
            projectId: "project-2",
            baseRef: "origin/main",
            baseRemoteName: "origin",
            branch: "fix/parser-crash-project-2",
            destinationPath: "/tmp/alas-mission-project-2",
            worktreeId: nil,
            worktreeLineageID: nil,
            agentId: "codex",
            acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            pendingInitialPrompt: "Fix issue #42 in project 2.",
            reviewIdentity: nil,
            state: .creating,
            setupCheckpoint: .creatingWorktree,
            attentionReason: nil,
            readinessEvidence: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        aggregate.legs.append(secondLeg)
        #expect(throws: MissionStore.Error.invalidLegCollection) { try store.insert(aggregate) }
    }

    @Test("adds a leg atomically to a running Mission")
    func addsLegToRunningMission() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs[0].state = .running
        aggregate.legs[0].setupCheckpoint = .running
        try store.insert(aggregate)
        let leg = MissionLeg(
            id: MissionLegID(rawValue: "mission-1-leg-2"),
            missionID: aggregate.mission.id,
            ordinal: 1,
            projectId: "project-2",
            baseRef: "origin/main",
            baseRemoteName: "origin",
            branch: "fix/parser-crash-project-2",
            destinationPath: "/tmp/alas-mission-project-2",
            worktreeId: nil,
            worktreeLineageID: nil,
            agentId: "codex",
            acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            pendingInitialPrompt: "Fix issue #42 in project 2.",
            reviewIdentity: nil,
            state: .creating,
            setupCheckpoint: .creatingWorktree,
            attentionReason: nil,
            readinessEvidence: nil,
            createdAt: Date(timeIntervalSince1970: 101),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let event = MissionFixtures.event(
            id: "leg-added",
            missionID: aggregate.mission.id,
            legID: leg.id,
            kind: .legAdded,
            createdAt: 102
        )

        try store.addLeg(leg, event: event)

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.legs == [aggregate.legs[0], leg])
        #expect(loaded.events.last == event)
        #expect(loaded.mission.updatedAt == event.createdAt)
    }

    @Test("persists an immutable prepared prompt after delivery is consumed")
    func persistsPreparedPromptAfterDelivery() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.legs[0].pendingInitialPrompt = nil
        try store.insert(aggregate)

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))

        #expect(loaded.primaryLeg?.preparedInitialPrompt == "Fix issue #42.")
        #expect(loaded.primaryLeg?.pendingInitialPrompt == nil)
    }

    @Test("requires a leg-added event to add a Mission leg")
    func requiresLegAddedEvent() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs[0].state = .running
        aggregate.legs[0].setupCheckpoint = .running
        try store.insert(aggregate)
        let leg = MissionFixtures.leg(
            id: MissionLegID(rawValue: "mission-1-leg-2"),
            missionID: aggregate.mission.id,
            ordinal: 1
        )

        #expect(throws: MissionStore.Error.invalidEventLeg) {
            try store.addLeg(leg, event: MissionFixtures.event(
                id: "not-a-leg-add",
                missionID: aggregate.mission.id,
                legID: leg.id,
                kind: .agentStarted
            ))
        }
    }

    @Test("rejects duplicate leg projects")
    func rejectsDuplicateLegProjects() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs[0].state = .running
        aggregate.legs[0].setupCheckpoint = .running
        var duplicate = aggregate.legs[0]
        duplicate = MissionLeg(
            id: MissionLegID(rawValue: "mission-1-leg-2"), missionID: duplicate.missionID, ordinal: 1,
            projectId: duplicate.projectId, baseRef: duplicate.baseRef, baseRemoteName: duplicate.baseRemoteName,
            branch: "other", destinationPath: "/tmp/other", worktreeId: nil, worktreeLineageID: nil,
            agentId: duplicate.agentId, acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            pendingInitialPrompt: duplicate.pendingInitialPrompt, reviewIdentity: nil,
            state: .creating, setupCheckpoint: .creatingWorktree, attentionReason: nil,
            readinessEvidence: nil, createdAt: duplicate.createdAt, updatedAt: duplicate.updatedAt
        )
        try store.insert(aggregate)
        #expect(throws: MissionStore.Error.duplicateLegProject) {
            try store.addLeg(duplicate, event: MissionFixtures.event(
                id: "leg-added",
                missionID: aggregate.mission.id,
                legID: duplicate.id,
                kind: .legAdded
            ))
        }
    }

    @Test("rejects noncontiguous leg ordinals")
    func rejectsNoncontiguousLegOrdinals() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        var leg = aggregate.legs[0]
        leg = MissionLeg(
            id: MissionLegID(rawValue: "mission-1-leg-2"), missionID: leg.missionID, ordinal: 2,
            projectId: "project-2", baseRef: leg.baseRef, baseRemoteName: leg.baseRemoteName,
            branch: "other", destinationPath: "/tmp/other", worktreeId: nil, worktreeLineageID: nil,
            agentId: leg.agentId, acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            pendingInitialPrompt: leg.pendingInitialPrompt, reviewIdentity: nil,
            state: .creating, setupCheckpoint: .creatingWorktree, attentionReason: nil,
            readinessEvidence: nil, createdAt: leg.createdAt, updatedAt: leg.updatedAt
        )
        try store.insert(aggregate)
        #expect(throws: MissionStore.Error.invalidLegCollection) {
            try store.addLeg(leg, event: MissionFixtures.event(
                id: "leg-added",
                missionID: aggregate.mission.id,
                legID: leg.id,
                kind: .legAdded
            ))
        }
    }

    @Test("rejects events addressed to legs outside the Mission")
    func rejectsEventForAnotherMissionLeg() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.events.append(MissionFixtures.event(
            id: "wrong-leg",
            missionID: aggregate.mission.id,
            legID: MissionLegID(rawValue: "other-mission-leg-1"),
            kind: .agentStarted,
            createdAt: 102
        ))

        #expect(throws: MissionStore.Error.invalidEventLeg) { try store.insert(aggregate) }
    }

    @Test("creates schema and persists ordered events across reopen")
    func persistsAggregateAndOrderedEventsAcrossReopen() throws {
        let path = temporaryPath()
        let aggregate = MissionFixtures.creatingMission()

        do {
            let store = try MissionStore(path: path)
            #expect(try store.currentSchemaVersion() == MissionStore.targetSchemaVersion)
            try store.insert(aggregate)
            var leg = try #require(aggregate.primaryLeg)
            leg.state = .running
            leg.setupCheckpoint = .running
            leg.updatedAt = Date(timeIntervalSince1970: 102)
            try store.updateLegSetup(
                missionID: aggregate.mission.id,
                leg: leg,
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
        #expect(loaded.primaryLeg?.setupCheckpoint == .running)
        #expect(loaded.primaryLeg?.baseRemoteName == "origin")
        #expect(loaded.events.map(\.id) == ["mission-1-event-1", "event-2"])
    }

    @Test("rejects aggregates without a primary leg")
    func rejectsMissingPrimaryLeg() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.legs = []

        #expect(throws: MissionStore.Error.invalidLegCollection) {
            try store.insert(aggregate)
        }
    }

    @Test("rejects a second active mission for the same issue identity")
    func rejectsDuplicateActiveIssueIdentity() throws {
        let store = try MissionStore(path: temporaryPath())
        try store.insert(MissionFixtures.creatingMission(id: "mission-1"))

        #expect(throws: MissionStore.Error.duplicateActiveSourceIdentity) {
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

        #expect(throws: MissionStore.Error.duplicateActiveSourceIdentity) {
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
        leg.state = .ready
        leg.readinessEvidence = .init(kind: .legacy, observedAt: Date(timeIntervalSince1970: 199))
        try store.updateLegSetup(missionID: aggregate.mission.id, leg: leg, event: nil)
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

        #expect(try store.activeMission(sourceIdentity: aggregate.source.identity) == nil)
        #expect(try store.aggregate(id: aggregate.mission.id)?.primaryLeg?.worktreeLineageID == "device:inode")
        try store.insert(MissionFixtures.creatingMission(id: "mission-2"))
        #expect(try store.activeMission(sourceIdentity: aggregate.source.identity)?.mission.id == MissionID(rawValue: "mission-2"))
    }

    @Test("manual completion preserves unfinished leg state")
    func manualCompletionPreservesUnfinishedLegState() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        aggregate.mission.state = .running
        aggregate.legs[0].state = .running
        aggregate.legs[0].setupCheckpoint = .running
        try store.insert(aggregate)
        let secondLeg = MissionFixtures.leg(
            id: MissionLegID(rawValue: "mission-1-leg-2"),
            missionID: aggregate.mission.id,
            ordinal: 1,
            projectId: "project-2"
        )
        try store.addLeg(secondLeg, event: MissionFixtures.event(
            id: "leg-added",
            missionID: aggregate.mission.id,
            legID: secondLeg.id,
            kind: .legAdded,
            createdAt: 111
        ))
        var firstLeg = try #require(aggregate.primaryLeg)
        firstLeg.state = .ready
        firstLeg.readinessEvidence = .init(kind: .mergedReview, observedAt: Date(timeIntervalSince1970: 110))
        try store.updateLegSetup(missionID: aggregate.mission.id, leg: firstLeg, event: nil)

        try store.complete(
            id: aggregate.mission.id,
            at: Date(timeIntervalSince1970: 120),
            event: MissionFixtures.event(id: "completed", kind: .completed, createdAt: 120)
        )

        let completed = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(completed.mission.state == .completed)
        #expect(completed.legs.first { $0.id == firstLeg.id }?.state == .ready)
        #expect(completed.legs.first { $0.id == secondLeg.id }?.state == .creating)
    }

    @Test("leg setup state and its event are committed together")
    func updatesLegSetupStateAndEventAtomically() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        var leg = try #require(aggregate.primaryLeg)
        leg.state = .needsAttention
        leg.setupCheckpoint = .startingAgent
        leg.attentionReason = "Agent authentication is required."
        leg.updatedAt = Date(timeIntervalSince1970: 120)
        try store.updateLegSetup(
            missionID: aggregate.mission.id,
            leg: leg,
            event: MissionFixtures.event(
                id: "attention",
                missionID: aggregate.mission.id,
                kind: .attentionRequired,
                createdAt: 120
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.primaryLeg?.state == .needsAttention)
        #expect(loaded.primaryLeg?.attentionReason == "Agent authentication is required.")
        #expect(loaded.events.last?.id == "attention")
    }

    @Test("leg setup writes cannot mutate completed Mission history")
    func rejectsLegSetupWritesAfterCompletion() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        try store.complete(
            id: aggregate.mission.id,
            at: Date(timeIntervalSince1970: 120),
            event: MissionFixtures.event(id: "completed", kind: .completed, createdAt: 120)
        )
        let completed = try #require(try store.aggregate(id: aggregate.mission.id))
        var leg = try #require(completed.primaryLeg)
        leg.state = .needsAttention
        leg.setupCheckpoint = .startingAgent
        leg.attentionReason = "Late setup failure."
        leg.updatedAt = Date(timeIntervalSince1970: 130)

        #expect(throws: MissionStore.Error.missionCompleted) {
            try store.updateLegSetup(
                missionID: aggregate.mission.id,
                leg: leg,
                event: MissionFixtures.event(
                    id: "late-attention",
                    missionID: aggregate.mission.id,
                    legID: leg.id,
                    kind: .attentionRequired,
                    createdAt: 130
                )
            )
        }

        #expect(try store.aggregate(id: aggregate.mission.id) == completed)
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
        try store.replaceSourceSnapshot(
            missionID: aggregate.mission.id,
            snapshot: MissionSourceSnapshot(issue: refreshed),
            event: MissionFixtures.event(
                id: "refreshed",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.source == MissionSourceSnapshot(issue: refreshed))
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

        try store.replaceSourceSnapshot(
            missionID: aggregate.mission.id,
            snapshot: MissionSourceSnapshot(issue: differentlyCasedIssue),
            event: MissionFixtures.event(
                id: "casing-refresh",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.source.identity == aggregate.source.identity)
        #expect(loaded.source.title == "Fresh title")
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
        try store.replaceSourceSnapshot(
            missionID: aggregate.mission.id,
            snapshot: MissionSourceSnapshot(issue: refreshed),
            event: MissionFixtures.event(
                id: "success-after-read",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 200
            )
        )
        try store.updateSourceRefreshError(
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
        #expect(stale.source.title != refreshed.title)
        #expect(loaded.source.title == refreshed.title)
        #expect(loaded.source.capturedAt == refreshed.capturedAt)
        #expect(loaded.source.refreshError == "Authentication is required for github.com.")
    }

    @Test("rejects a refreshed snapshot that changes the mission issue identity")
    func rejectsIssueIdentityChangeDuringRefresh() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        let changedIdentity = MissionFixtures.issue(number: 43, capturedAt: 150)

        #expect(throws: MissionStore.Error.sourceIdentityChanged) {
            try store.replaceSourceSnapshot(
                missionID: aggregate.mission.id,
                snapshot: MissionSourceSnapshot(issue: changedIdentity),
                event: MissionFixtures.event(
                    id: "wrong-identity-refresh",
                    missionID: aggregate.mission.id,
                    kind: .sourceRefreshed,
                    createdAt: 150
                )
            )
        }

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.source == aggregate.source)
        #expect(loaded.events.map(\.id) == ["mission-1-event-1"])
    }

    @Test("rejects a repository redirect whose stable ID does not match its locator")
    func rejectsIncoherentRepositoryRedirectIdentity() throws {
        let store = try MissionStore(path: temporaryPath())
        let aggregate = MissionFixtures.creatingMission()
        try store.insert(aggregate)
        let source = aggregate.source
        let replacement = MissionSourceSnapshot(
            identity: .init(
                providerID: .github,
                stableID: "github.com/unrelated/project#42"
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            providerLabel: source.providerLabel,
            displayReference: source.displayReference,
            repositoryLocator: .init(
                provider: .github,
                host: "github.com",
                repositorySlug: "acquired/renamed-alas"
            ),
            title: "Fresh after rename",
            body: source.body,
            state: source.state,
            labels: source.labels,
            assignees: source.assignees,
            providerUpdatedAt: source.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 150),
            refreshError: nil,
            contentOrigin: source.contentOrigin,
            isEditable: source.isEditable,
            isRefreshable: source.isRefreshable
        )

        #expect(throws: MissionStore.Error.sourceIdentityChanged) {
            try store.replaceSourceSnapshot(
                missionID: aggregate.mission.id,
                snapshot: replacement,
                event: MissionFixtures.event(
                    id: "incoherent-rename-refresh",
                    missionID: aggregate.mission.id,
                    kind: .sourceRefreshed,
                    createdAt: 150
                )
            )
        }

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.source == aggregate.source)
        #expect(loaded.events.map(\.id) == ["mission-1-event-1"])
    }

    @Test("migrates a provider-confirmed repository rename and its linked review")
    func migratesRepositoryRenameDuringRefresh() throws {
        let store = try MissionStore(path: temporaryPath())
        var aggregate = MissionFixtures.creatingMission()
        let issue = try #require(MissionIssueSnapshot(source: aggregate.source))
        let locator = try #require(aggregate.source.repositoryLocator)
        aggregate.legs[0].reviewIdentity = MissionReviewIdentity(
            provider: locator.provider,
            host: locator.host,
            repositorySlug: locator.repositorySlug,
            number: 17,
            url: URL(string: "https://github.com/acme/alas/pull/17")!
        )
        try store.insert(aggregate)
        let renamed = MissionIssueSnapshot(
            identity: .init(
                provider: issue.identity.provider,
                host: issue.identity.host,
                repositorySlug: "acquired/renamed-alas",
                number: issue.identity.number
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            title: "Fresh after rename",
            body: aggregate.source.body,
            state: issue.state,
            labels: aggregate.source.labels,
            assignees: aggregate.source.assignees,
            providerUpdatedAt: aggregate.source.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 150),
            refreshError: nil
        )

        try store.replaceSourceSnapshot(
            missionID: aggregate.mission.id,
            snapshot: MissionSourceSnapshot(issue: renamed),
            event: MissionFixtures.event(
                id: "rename-refresh",
                missionID: aggregate.mission.id,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loaded = try #require(try store.aggregate(id: aggregate.mission.id))
        #expect(loaded.source.identity == MissionSourceSnapshot(issue: renamed).identity)
        #expect(loaded.primaryLeg?.reviewIdentity?.repositorySlug == "acquired/renamed-alas")
        #expect(loaded.primaryLeg?.reviewIdentity?.number == 17)
    }

    @Test("rejects a repository rename that collides with another active mission")
    func rejectsRepositoryRenameWithActiveCanonicalMission() throws {
        let store = try MissionStore(path: temporaryPath())
        let legacy = MissionFixtures.creatingMission(id: "legacy-mission")
        let legacyIssue = try #require(MissionIssueSnapshot(source: legacy.source))
        let canonicalIssue = MissionIssueSnapshot(
            identity: .init(
                provider: legacyIssue.identity.provider,
                host: legacyIssue.identity.host,
                repositorySlug: "acquired/renamed-alas",
                number: legacyIssue.identity.number
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            title: "Canonical issue",
            body: legacy.source.body,
            state: legacyIssue.state,
            labels: legacy.source.labels,
            assignees: legacy.source.assignees,
            providerUpdatedAt: legacy.source.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 150),
            refreshError: nil
        )
        let canonical = MissionFixtures.creatingMission(id: "canonical-mission", issue: canonicalIssue)
        try store.insert(legacy)
        try store.insert(canonical)

        #expect(throws: MissionStore.Error.duplicateActiveSourceIdentity) {
            try store.replaceSourceSnapshot(
                missionID: legacy.mission.id,
                snapshot: MissionSourceSnapshot(issue: canonicalIssue),
                event: MissionFixtures.event(
                    id: "rename-refresh",
                    missionID: legacy.mission.id,
                    kind: .sourceRefreshed,
                    createdAt: 150
                )
            )
        }

        let loaded = try #require(try store.aggregate(id: legacy.mission.id))
        #expect(loaded.source == legacy.source)
        #expect(loaded.events.map(\.id) == ["legacy-mission-event-1"])
    }

    @Test("repository rename migrates an explicitly duplicated mission cohort")
    func repositoryRenameMigratesExplicitDuplicateCohort() throws {
        let store = try MissionStore(path: temporaryPath())
        let first = MissionFixtures.creatingMission(id: "first-mission")
        let firstIssue = try #require(MissionIssueSnapshot(source: first.source))
        var second = MissionFixtures.creatingMission(id: "second-mission")
        let secondLocator = try #require(second.source.repositoryLocator)
        second.legs[0].reviewIdentity = MissionReviewIdentity(
            provider: secondLocator.provider,
            host: secondLocator.host,
            repositorySlug: secondLocator.repositorySlug,
            number: 17,
            url: URL(string: "https://github.com/acme/alas/pull/17")!
        )
        try store.insert(first)
        try store.insert(second, allowDuplicate: true)
        let renamed = MissionIssueSnapshot(
            identity: .init(
                provider: firstIssue.identity.provider,
                host: firstIssue.identity.host,
                repositorySlug: "acquired/renamed-alas",
                number: firstIssue.identity.number
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            title: "Fresh after rename",
            body: first.source.body,
            state: firstIssue.state,
            labels: first.source.labels,
            assignees: first.source.assignees,
            providerUpdatedAt: first.source.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 150),
            refreshError: nil
        )

        try store.replaceSourceSnapshot(
            missionID: first.mission.id,
            snapshot: MissionSourceSnapshot(issue: renamed),
            event: MissionFixtures.event(
                id: "rename-refresh",
                missionID: first.mission.id,
                legID: nil,
                kind: .sourceRefreshed,
                createdAt: 150
            )
        )

        let loadedFirst = try #require(try store.aggregate(id: first.mission.id))
        let loadedSecond = try #require(try store.aggregate(id: second.mission.id))
        #expect(loadedFirst.source.identity == MissionSourceSnapshot(issue: renamed).identity)
        #expect(loadedSecond.source.identity == MissionSourceSnapshot(issue: renamed).identity)
        #expect(loadedSecond.source.canonicalURL == renamed.canonicalURL)
        #expect(loadedSecond.primaryLeg?.reviewIdentity?.repositorySlug == "acquired/renamed-alas")
        #expect(loadedSecond.events.map(\.id) == ["second-mission-event-1"])
    }

    @Test("completed mission refresh rejects a rename that collides with an active cohort")
    func completedMissionRefreshRejectsRepositoryRenameCollision() throws {
        let store = try MissionStore(path: temporaryPath())
        let completed = MissionFixtures.creatingMission(id: "completed-mission")
        let completedIssue = try #require(MissionIssueSnapshot(source: completed.source))
        try store.insert(completed)
        var completedLeg = try #require(completed.primaryLeg)
        completedLeg.state = .ready
        completedLeg.readinessEvidence = .init(kind: .legacy, observedAt: Date(timeIntervalSince1970: 124))
        try store.updateLegSetup(missionID: completed.mission.id, leg: completedLeg, event: nil)
        try store.complete(
            id: completed.mission.id,
            at: Date(timeIntervalSince1970: 125),
            event: MissionFixtures.event(
                id: "completed",
                missionID: completed.mission.id,
                legID: nil,
                kind: .completed,
                createdAt: 125
            )
        )
        let activeLegacy = MissionFixtures.creatingMission(id: "active-legacy")
        try store.insert(activeLegacy)
        let canonicalIssue = MissionIssueSnapshot(
            identity: .init(
                provider: completedIssue.identity.provider,
                host: completedIssue.identity.host,
                repositorySlug: "acquired/renamed-alas",
                number: completedIssue.identity.number
            ),
            canonicalURL: URL(string: "https://github.com/acquired/renamed-alas/issues/42")!,
            title: "Canonical issue",
            body: completed.source.body,
            state: completedIssue.state,
            labels: completed.source.labels,
            assignees: completed.source.assignees,
            providerUpdatedAt: completed.source.providerUpdatedAt,
            capturedAt: Date(timeIntervalSince1970: 150),
            refreshError: nil
        )
        let activeCanonical = MissionFixtures.creatingMission(
            id: "active-canonical",
            issue: canonicalIssue
        )
        try store.insert(activeCanonical)

        #expect(throws: MissionStore.Error.duplicateActiveSourceIdentity) {
            try store.replaceSourceSnapshot(
                missionID: completed.mission.id,
                snapshot: MissionSourceSnapshot(issue: canonicalIssue),
                event: MissionFixtures.event(
                    id: "rename-refresh",
                    missionID: completed.mission.id,
                    legID: nil,
                    kind: .sourceRefreshed,
                    createdAt: 150
                )
            )
        }

        #expect(try store.aggregate(id: completed.mission.id)?.source == completed.source)
        #expect(try store.aggregate(id: activeLegacy.mission.id)?.source == activeLegacy.source)
        #expect(try store.aggregate(id: activeCanonical.mission.id)?.source == MissionSourceSnapshot(issue: canonicalIssue))
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
        var completedLeg = try #require(completed.primaryLeg)
        completedLeg.state = .ready
        completedLeg.readinessEvidence = .init(kind: .legacy, observedAt: Date(timeIntervalSince1970: 399))
        try store.updateLegSetup(missionID: completed.mission.id, leg: completedLeg, event: nil)
        try store.complete(
            id: completed.mission.id,
            at: Date(timeIntervalSince1970: 400),
            event: MissionFixtures.event(
                id: "completed-event",
                missionID: completed.mission.id,
                legID: nil,
                kind: .completed,
                createdAt: 400
            )
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

private enum MissionStoreTestDatabase {
    static func v5(path: URL, provider: String = "github") throws -> SQLiteDatabase {
        do {
            _ = try v3(
                path: path,
                missionState: "running",
                checkpoint: "running",
                attentionReason: nil
            )
        }
        if provider != "github" {
            let database = try SQLiteDatabase(path: path.path)
            try database.exec("UPDATE mission_issue_sources SET provider = ?", bindings: [provider])
        }
        do { _ = try MissionStore(path: path.path, schemaTargetVersion: 5) }
        return try SQLiteDatabase(path: path.path)
    }

    static func v3(
        path: URL,
        missionState: String,
        checkpoint: String,
        attentionReason: String?
    ) throws -> SQLiteDatabase {
        do { _ = try MissionStore(path: path.path, schemaTargetVersion: 1) }
        do { _ = try MissionStore(path: path.path, schemaTargetVersion: 3) }
        let database = try SQLiteDatabase(path: path.path)

        let encoded = JSONEncoder()
        try database.exec("""
        INSERT INTO missions (
          id, title, source_kind, state, setup_checkpoint, primary_leg_id,
          attention_reason, created_at, updated_at, completed_at
        ) VALUES (?, ?, 'issue', ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            "mission-1", "Fix parser crash", missionState, checkpoint, "leg-1", attentionReason,
            100.0, 101.0, missionState == "completed" ? 101.0 : nil,
        ])
        try database.exec("""
        INSERT INTO mission_issue_sources (
          mission_id, provider, host, repository_slug, issue_number, canonical_url,
          title, body, provider_state, labels, assignees, provider_updated_at, captured_at, refresh_error
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            "mission-1", "github", "github.com", "acme/alas", 42,
            "https://github.com/acme/alas/issues/42", "Fix parser crash", "The parser crashes.", "open",
            try encoded.encode(["bug"]), try encoded.encode(["nacho"]), 90.0, 100.0, nil,
        ])
        try database.exec("""
        INSERT INTO mission_legs (
          id, mission_id, ordinal, project_id, base_ref, base_remote_name, branch, destination_path,
          worktree_id, worktree_lineage_id, agent_id, acp_session_id, initial_prompt_id,
          pending_initial_prompt, review_identity
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            "leg-1", "mission-1", 0, "project-1", "origin/main", "origin", "fix/parser-crash",
            "/tmp/alas-mission", nil, nil, "codex", nil,
            "00000000-0000-0000-0000-000000000001", "Fix issue #42.", nil,
        ])
        try database.exec("""
        INSERT INTO mission_events (id, mission_id, leg_id, kind, message, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """, bindings: ["event-1", "mission-1", "leg-1", "created", "Mission created.", 100.0])
        return database
    }
}
