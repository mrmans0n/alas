import Foundation

final class MissionStore {
    enum Error: Swift.Error, Equatable {
        // Temporary source compatibility while callers migrate to the explicit
        // multi-leg validation errors below.
        case exactlyOneLeg
        case duplicateActiveSourceIdentity
        case sourceIdentityChanged
        case sourceNotEditable
        // Temporary compatibility while issue-only callers migrate.
        case duplicateActiveIssueIdentity
        case issueIdentityChanged
        case malformedRecord
        case missionNotFound
        case missionCompleted
        case invalidEvent
        case invalidLegCollection
        case duplicateLegProject
        case invalidEventLeg
    }

    static let targetSchemaVersion = 6

    let path: String
    let db: SQLiteDatabase
    private let schemaTargetVersion: Int

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(
        path: String,
        busyTimeoutMilliseconds: Int32 = 5_000,
        schemaTargetVersion: Int = MissionStore.targetSchemaVersion
    ) throws {
        self.path = path
        self.schemaTargetVersion = schemaTargetVersion
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        self.db = try SQLiteDatabase(path: path, busyTimeoutMilliseconds: busyTimeoutMilliseconds)
        try migrate()
    }

    func currentSchemaVersion() throws -> Int {
        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        return Int((rows.first?["version"] as? Int64) ?? 0)
    }

    func insert(_ aggregate: MissionAggregate, allowDuplicate: Bool = false) throws {
        try validate(aggregate)
        guard aggregate.legs.count == 1 else { throw Error.invalidLegCollection }
        try immediateTransaction {
            if !allowDuplicate {
                let identity = aggregate.source.identity
                let duplicate = try db.query("""
                SELECT missions.id
                FROM missions
                JOIN mission_sources ON mission_sources.mission_id = missions.id
                WHERE provider_id = ? AND stable_id = ?
                  AND state != ?
                LIMIT 1
                """, bindings: [
                    identity.providerID.rawValue,
                    identity.stableID,
                    MissionState.completed.rawValue,
                ])
                if !duplicate.isEmpty { throw Error.duplicateActiveSourceIdentity }
            }

            try insertMission(aggregate.mission, initialLeg: aggregate.legs[0])
            try insertSource(aggregate.source, missionID: aggregate.mission.id)
            try insertLeg(aggregate.legs[0])
            for event in aggregate.events { try insertEvent(event) }
        }
    }

    func aggregate(id: MissionID) throws -> MissionAggregate? {
        let rows = try db.query("SELECT * FROM missions WHERE id = ?", bindings: [id.rawValue])
        guard let missionRow = rows.first else { return nil }
        var mission = try decodeMission(missionRow)
        let sourceRows = try db.query(
            "SELECT * FROM mission_sources WHERE mission_id = ?",
            bindings: [id.rawValue]
        )
        guard let sourceRow = sourceRows.first else { throw Error.malformedRecord }
        let legs = try db.query(
            "SELECT * FROM mission_legs WHERE mission_id = ? ORDER BY ordinal ASC, id ASC",
            bindings: [id.rawValue]
        ).map(decodeLeg)
        let events = try db.query(
            "SELECT * FROM mission_events WHERE mission_id = ? ORDER BY created_at ASC, rowid ASC",
            bindings: [id.rawValue]
        ).map(decodeEvent)
        var aggregate = MissionAggregate(
            mission: mission,
            source: try decodeSource(sourceRow),
            legs: legs,
            events: events
        )
        try validate(aggregate)
        applyLegacyPresentation(to: &aggregate)
        return aggregate
    }

    func list(includeCompleted: Bool) throws -> [MissionAggregate] {
        let whereClause = includeCompleted ? "" : "WHERE state != ?"
        let bindings: [Any?] = includeCompleted ? [] : [MissionState.completed.rawValue]
        let ids = try db.query("""
        SELECT id FROM missions
        \(whereClause)
        ORDER BY CASE state WHEN 'completed' THEN 1 ELSE 0 END ASC, updated_at DESC, id ASC
        """, bindings: bindings).compactMap { $0["id"] as? String }
        return try ids.compactMap { try aggregate(id: MissionID(rawValue: $0)) }
    }

    func list(states: Set<MissionState>) throws -> [MissionAggregate] {
        guard !states.isEmpty else { return [] }
        let orderedStates = states.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: orderedStates.count).joined(separator: ", ")
        let ids = try db.query("""
        SELECT id FROM missions
        WHERE state IN (\(placeholders))
        ORDER BY CASE state WHEN 'completed' THEN 1 ELSE 0 END ASC, updated_at DESC, id ASC
        """, bindings: orderedStates).compactMap { $0["id"] as? String }
        return try ids.compactMap { try aggregate(id: MissionID(rawValue: $0)) }
    }

    func activeMission(sourceIdentity: MissionSourceIdentity) throws -> MissionAggregate? {
        let rows = try db.query("""
        SELECT missions.id
        FROM missions
        JOIN mission_sources ON mission_sources.mission_id = missions.id
        WHERE provider_id = ? AND stable_id = ?
          AND state != ?
        ORDER BY updated_at DESC, missions.id ASC
        LIMIT 1
        """, bindings: [
            sourceIdentity.providerID.rawValue,
            sourceIdentity.stableID,
            MissionState.completed.rawValue,
        ])
        guard let id = rows.first?["id"] as? String else { return nil }
        return try aggregate(id: MissionID(rawValue: id))
    }

    func activeMission(issueIdentity: MissionIssueIdentity) throws -> MissionAggregate? {
        let providerID: MissionSourceProviderID = switch issueIdentity.provider {
        case .github: .github
        case .gitlab: .gitlab
        }
        return try activeMission(sourceIdentity: .init(
            providerID: providerID,
            stableID: "\(issueIdentity.host)/\(issueIdentity.repositorySlug)#\(issueIdentity.number)".lowercased()
        ))
    }

    func leg(missionID: MissionID, legID: MissionLegID) throws -> MissionLeg? {
        let rows = try db.query(
            "SELECT * FROM mission_legs WHERE id = ? AND mission_id = ?",
            bindings: [legID.rawValue, missionID.rawValue]
        )
        return try rows.first.map(decodeLeg)
    }

    func addLeg(_ leg: MissionLeg, event: MissionEvent) throws {
        guard event.kind == .legAdded,
              event.missionID == leg.missionID,
              event.legID == leg.id
        else { throw Error.invalidEventLeg }
        try immediateTransaction {
            let aggregate = try requireAggregate(leg.missionID)
            guard aggregate.mission.state == .running else { throw Error.invalidLegCollection }
            guard leg.ordinal == aggregate.legs.count else { throw Error.invalidLegCollection }
            guard !aggregate.legs.contains(where: { $0.projectId == leg.projectId }) else {
                throw Error.duplicateLegProject
            }
            try insertLeg(leg)
            try updateMissionState(
                missionID: leg.missionID,
                legs: aggregate.legs + [leg],
                updatedAt: event.createdAt
            )
            try insertEvent(event)
        }
    }

    func updateSetup(
        id: MissionID,
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        attentionReason: String?,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: id)
        try immediateTransaction {
            let aggregate = try requireAggregate(id)
            if var leg = aggregate.primaryLeg {
                leg.state = Self.legState(for: state, checkpoint: checkpoint)
                leg.setupCheckpoint = checkpoint
                leg.attentionReason = attentionReason
                leg.updatedAt = event.createdAt
                try updateLegRecord(leg)
                try updateMissionState(
                    missionID: id,
                    legs: replacing(leg, in: aggregate.legs),
                    updatedAt: event.createdAt
                )
            }
            try insertEvent(event)
        }
    }

    func updateLeg(_ leg: MissionLeg, event: MissionEvent?) throws {
        if let event { try validate(event: event, for: leg.missionID, legID: leg.id) }
        try immediateTransaction {
            let aggregate = try requireAggregate(leg.missionID)
            try updateLegRecord(leg)
            let updatedAt = event?.createdAt ?? leg.updatedAt
            try updateMissionState(
                missionID: leg.missionID,
                legs: replacing(leg, in: aggregate.legs),
                updatedAt: updatedAt
            )
            if let event { try insertEvent(event) }
        }
    }

    func updateLegSetup(
        missionID: MissionID,
        leg: MissionLeg,
        event: MissionEvent?
    ) throws {
        guard leg.missionID == missionID else { throw Error.invalidLegCollection }
        if let event { try validate(event: event, for: missionID, legID: leg.id) }
        try immediateTransaction {
            let aggregate = try requireAggregate(missionID)
            guard aggregate.mission.state != .completed else { throw Error.missionCompleted }
            try updateLegRecord(leg)
            let updatedAt = event?.createdAt ?? leg.updatedAt
            try updateMissionState(
                missionID: missionID,
                legs: replacing(leg, in: aggregate.legs),
                updatedAt: updatedAt
            )
            if let event { try insertEvent(event) }
        }
    }

    func updateSetup(
        id: MissionID,
        leg: MissionLeg,
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        attentionReason: String?,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: id, legID: leg.id)
        guard leg.missionID == id else { throw Error.invalidLegCollection }
        try immediateTransaction {
            let aggregate = try requireAggregate(id)
            var updatedLeg = leg
            updatedLeg.state = Self.legState(for: state, checkpoint: checkpoint)
            updatedLeg.setupCheckpoint = checkpoint
            updatedLeg.attentionReason = attentionReason
            updatedLeg.updatedAt = event.createdAt
            try updateLegRecord(updatedLeg)
            try updateMissionState(
                missionID: id,
                legs: replacing(updatedLeg, in: aggregate.legs),
                updatedAt: event.createdAt
            )
            try insertEvent(event)
        }
    }

    @discardableResult
    func replaceSourceSnapshot(
        missionID: MissionID,
        snapshot: MissionSourceSnapshot,
        event: MissionEvent
    ) throws -> [MissionID] {
        try validate(event: event, for: missionID)
        return try immediateTransaction {
            try requireMission(missionID)
            let storedSource = try source(missionID: missionID)
            let identityChanged = storedSource.identity != snapshot.identity
            if identityChanged,
               !Self.isAllowedCodeHostRedirect(from: storedSource, to: snapshot) {
                throw Error.sourceIdentityChanged
            }
            if identityChanged,
               try hasActiveSourceIdentityCollision(
                   missionID: missionID,
                   storedIdentity: storedSource.identity,
                   replacementIdentity: snapshot.identity
               ) {
                throw Error.duplicateActiveSourceIdentity
            }
            let migratedDuplicateIDs: [MissionID]
            if identityChanged {
                migratedDuplicateIDs = try migrateActiveDuplicateSourceIdentities(
                    excluding: missionID,
                    from: storedSource,
                    to: snapshot
                )
            } else {
                migratedDuplicateIDs = []
            }
            let changed = try db.execChanges("""
            UPDATE mission_sources
            SET provider_id = ?, stable_id = ?, canonical_url = ?, provider_label = ?,
                display_reference = ?, repository_locator = ?, title = ?, body = ?,
                provider_state = ?, labels = ?, assignees = ?, provider_updated_at = ?,
                captured_at = ?, refresh_error = ?, content_origin = ?, is_editable = ?,
                is_refreshable = ?
            WHERE mission_id = ?
            """, bindings: sourceBindings(snapshot) + [missionID.rawValue])
            guard changed == 1 else { throw Error.malformedRecord }
            if identityChanged,
               let oldLocator = storedSource.repositoryLocator,
               let newLocator = snapshot.repositoryLocator {
                try migrateReviewIdentities(
                    missionID: missionID,
                    from: oldLocator,
                    to: newLocator
                )
            }
            try db.exec("UPDATE missions SET title = ?, updated_at = ? WHERE id = ?", bindings: [
                snapshot.title,
                event.createdAt.timeIntervalSince1970,
                missionID.rawValue,
            ])
            try insertEvent(event)
            return [missionID] + migratedDuplicateIDs
        }
    }

    @discardableResult
    func replaceIssueSnapshot(
        missionID: MissionID,
        snapshot: MissionIssueSnapshot,
        event: MissionEvent
    ) throws -> [MissionID] {
        try replaceSourceSnapshot(
            missionID: missionID,
            snapshot: MissionSourceSnapshot(issue: snapshot),
            event: event
        )
    }

    private func hasActiveSourceIdentityCollision(
        missionID: MissionID,
        storedIdentity: MissionSourceIdentity,
        replacementIdentity: MissionSourceIdentity
    ) throws -> Bool {
        let rows = try db.query("""
        SELECT 1
        WHERE (
            EXISTS (
              SELECT 1
              FROM missions AS source
              WHERE source.id = ? AND source.state != ?
            )
            OR EXISTS (
              SELECT 1
              FROM missions AS cohort
              JOIN mission_sources AS source ON source.mission_id = cohort.id
              WHERE cohort.id != ? AND cohort.state != ?
                AND source.provider_id = ? AND source.stable_id = ?
            )
          )
          AND EXISTS (
            SELECT 1
            FROM missions AS duplicate
            JOIN mission_sources AS source ON source.mission_id = duplicate.id
            WHERE duplicate.id != ? AND duplicate.state != ?
              AND source.provider_id = ? AND source.stable_id = ?
          )
        LIMIT 1
        """, bindings: [
            missionID.rawValue,
            MissionState.completed.rawValue,
            missionID.rawValue,
            MissionState.completed.rawValue,
            storedIdentity.providerID.rawValue,
            storedIdentity.stableID,
            missionID.rawValue,
            MissionState.completed.rawValue,
            replacementIdentity.providerID.rawValue,
            replacementIdentity.stableID,
        ])
        return !rows.isEmpty
    }

    private func migrateActiveDuplicateSourceIdentities(
        excluding missionID: MissionID,
        from storedSource: MissionSourceSnapshot,
        to snapshot: MissionSourceSnapshot
    ) throws -> [MissionID] {
        let duplicateIDs = try db.query("""
        SELECT missions.id
        FROM missions
        JOIN mission_sources AS source ON source.mission_id = missions.id
        WHERE missions.id != ? AND missions.state != ?
          AND source.provider_id = ? AND source.stable_id = ?
        """, bindings: [
            missionID.rawValue,
            MissionState.completed.rawValue,
            storedSource.identity.providerID.rawValue,
            storedSource.identity.stableID,
        ]).compactMap { $0["id"] as? String }

        for duplicateID in duplicateIDs {
            let duplicateMissionID = MissionID(rawValue: duplicateID)
            let changed = try db.execChanges("""
            UPDATE mission_sources
            SET provider_id = ?, stable_id = ?, canonical_url = ?, provider_label = ?,
                display_reference = ?, repository_locator = ?
            WHERE mission_id = ?
            """, bindings: [
                snapshot.identity.providerID.rawValue,
                snapshot.identity.stableID,
                snapshot.canonicalURL.absoluteString,
                snapshot.providerLabel,
                snapshot.displayReference,
                try snapshot.repositoryLocator.map(encoder.encode),
                duplicateID,
            ])
            guard changed == 1 else { throw Error.malformedRecord }
            if let oldLocator = storedSource.repositoryLocator,
               let newLocator = snapshot.repositoryLocator {
                try migrateReviewIdentities(
                    missionID: duplicateMissionID,
                    from: oldLocator,
                    to: newLocator
                )
            }
        }
        return duplicateIDs.map { MissionID(rawValue: $0) }
    }

    func updateSourceRefreshError(
        missionID: MissionID,
        refreshError: String,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: missionID)
        try immediateTransaction {
            try requireMission(missionID)
            let changed = try db.execChanges(
                "UPDATE mission_sources SET refresh_error = ? WHERE mission_id = ?",
                bindings: [refreshError, missionID.rawValue]
            )
            guard changed == 1 else { throw Error.malformedRecord }
            try db.exec("UPDATE missions SET updated_at = ? WHERE id = ?", bindings: [
                event.createdAt.timeIntervalSince1970,
                missionID.rawValue,
            ])
            try insertEvent(event)
        }
    }

    func updateIssueRefreshError(
        missionID: MissionID,
        refreshError: String,
        event: MissionEvent
    ) throws {
        try updateSourceRefreshError(
            missionID: missionID,
            refreshError: refreshError,
            event: event
        )
    }

    func updateManualSourceContent(
        missionID: MissionID,
        title: String,
        body: String,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: missionID)
        guard event.kind == .sourceRefreshed else { throw Error.invalidEvent }
        try immediateTransaction {
            let storedSource = try source(missionID: missionID)
            guard storedSource.isEditable else { throw Error.sourceNotEditable }
            let changed = try db.execChanges(
                "UPDATE mission_sources SET title = ?, body = ? WHERE mission_id = ?",
                bindings: [title, body, missionID.rawValue]
            )
            guard changed == 1 else { throw Error.malformedRecord }
            try db.exec("UPDATE missions SET title = ?, updated_at = ? WHERE id = ?", bindings: [
                title,
                event.createdAt.timeIntervalSince1970,
                missionID.rawValue,
            ])
            try insertEvent(.init(
                id: event.id,
                missionID: event.missionID,
                legID: event.legID,
                kind: .sourceRefreshed,
                message: "Source context updated.",
                createdAt: event.createdAt
            ))
        }
    }

    func markReady(
        id: MissionID,
        reviewIdentity: MissionReviewIdentity?,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: id)
        try immediateTransaction {
            let aggregate = try requireAggregate(id)
            guard var primaryLeg = aggregate.primaryLeg else { throw Error.invalidLegCollection }
            primaryLeg.reviewIdentity = reviewIdentity
            primaryLeg.state = .ready
            primaryLeg.setupCheckpoint = .running
            primaryLeg.attentionReason = nil
            primaryLeg.readinessEvidence = .init(kind: .mergedReview, observedAt: event.createdAt)
            primaryLeg.updatedAt = event.createdAt
            try updateLegRecord(primaryLeg)
            try updateMissionState(
                missionID: id,
                legs: replacing(primaryLeg, in: aggregate.legs),
                updatedAt: event.createdAt
            )
            try insertEvent(event)
        }
    }

    func complete(id: MissionID, leg: MissionLeg? = nil, at: Date, event: MissionEvent) throws {
        try validate(event: event, for: id)
        if let leg, leg.missionID != id { throw Error.malformedRecord }
        try immediateTransaction {
            _ = try requireAggregate(id)
            if let leg {
                let changed = try db.execChanges("""
                UPDATE mission_legs
                SET worktree_lineage_id = ?
                WHERE id = ? AND mission_id = ?
                """, bindings: [
                    leg.worktreeLineageID,
                    leg.id.rawValue,
                    id.rawValue,
                ])
                guard changed == 1 else { throw Error.missionNotFound }
            }
            try db.exec("""
            UPDATE missions
            SET state = ?, updated_at = ?, completed_at = ?
            WHERE id = ?
            """, bindings: [
                MissionState.completed.rawValue,
                at.timeIntervalSince1970,
                at.timeIntervalSince1970,
                id.rawValue,
            ])
            try insertEvent(event)
        }
    }

    private func migrate() throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
        var current = try currentSchemaVersion()
        if current < 1, schemaTargetVersion >= 1 {
            try migrate(to: 1, migrateToV1)
            current = 1
        }
        if current < 2, schemaTargetVersion >= 2 {
            try migrate(to: 2, migrateToV2)
            current = 2
        }
        if current < 3, schemaTargetVersion >= 3 {
            try migrate(to: 3, migrateToV3)
            current = 3
        }
        if current < 4, schemaTargetVersion >= 4 {
            try migrate(to: 4, migrateToV4)
            current = 4
        }
        if current < 5, schemaTargetVersion >= 5 {
            try migrate(to: 5, migrateToV5)
            current = 5
        }
        if current < 6, schemaTargetVersion >= 6 {
            try migrate(to: 6, migrateToV6)
        }
    }

    private func migrate(to version: Int, _ changes: () throws -> Void) throws {
        try immediateTransaction {
            try changes()
            if try currentSchemaVersion() == 0 {
                try db.exec("INSERT INTO schema_version (version) VALUES (?)", bindings: [Int64(version)])
            } else {
                try db.exec("UPDATE schema_version SET version = ?", bindings: [Int64(version)])
            }
        }
    }

    private func migrateToV1() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS missions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          source_kind TEXT NOT NULL CHECK (source_kind = 'issue'),
          state TEXT NOT NULL,
          setup_checkpoint TEXT NOT NULL,
          primary_leg_id TEXT NOT NULL,
          attention_reason TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          completed_at REAL
        )
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS mission_issue_sources (
          mission_id TEXT PRIMARY KEY REFERENCES missions(id) ON DELETE CASCADE,
          provider TEXT NOT NULL,
          host TEXT NOT NULL,
          repository_slug TEXT NOT NULL,
          issue_number INTEGER NOT NULL,
          canonical_url TEXT NOT NULL,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          provider_state TEXT NOT NULL,
          labels BLOB NOT NULL,
          assignees BLOB NOT NULL,
          provider_updated_at REAL,
          captured_at REAL NOT NULL,
          refresh_error TEXT
        )
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS mission_legs (
          id TEXT PRIMARY KEY,
          mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL,
          project_id TEXT NOT NULL,
          base_ref TEXT NOT NULL,
          branch TEXT NOT NULL,
          destination_path TEXT NOT NULL,
          worktree_id TEXT,
          agent_id TEXT NOT NULL,
          acp_session_id TEXT,
          initial_prompt_id TEXT NOT NULL,
          pending_initial_prompt TEXT,
          review_identity BLOB,
          UNIQUE(mission_id, ordinal)
        )
        """)
        try db.exec("""
        CREATE TABLE IF NOT EXISTS mission_events (
          id TEXT PRIMARY KEY,
          mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
          leg_id TEXT,
          kind TEXT NOT NULL,
          message TEXT NOT NULL,
          created_at REAL NOT NULL
        )
        """)
        try db.exec("""
        CREATE INDEX IF NOT EXISTS mission_issue_sources_identity_idx
        ON mission_issue_sources(provider, host, repository_slug, issue_number)
        """)
        try db.exec("CREATE INDEX IF NOT EXISTS missions_state_updated_idx ON missions(state, updated_at)")
        try db.exec("CREATE INDEX IF NOT EXISTS mission_legs_project_idx ON mission_legs(project_id)")
        try db.exec("CREATE INDEX IF NOT EXISTS mission_legs_worktree_idx ON mission_legs(worktree_id)")
        try db.exec("CREATE INDEX IF NOT EXISTS mission_events_mission_created_idx ON mission_events(mission_id, created_at)")
    }

    private func migrateToV2() throws {
        try db.exec("ALTER TABLE mission_legs ADD COLUMN base_remote_name TEXT")
    }

    private func migrateToV3() throws {
        try db.exec("ALTER TABLE mission_legs ADD COLUMN worktree_lineage_id TEXT")
    }

    private func migrateToV4() throws {
        try db.exec("ALTER TABLE mission_legs ADD COLUMN state TEXT NOT NULL DEFAULT 'creating'")
        try db.exec("ALTER TABLE mission_legs ADD COLUMN setup_checkpoint TEXT NOT NULL DEFAULT 'creatingWorktree'")
        try db.exec("ALTER TABLE mission_legs ADD COLUMN attention_reason TEXT")
        try db.exec("ALTER TABLE mission_legs ADD COLUMN readiness_evidence BLOB")
        try db.exec("ALTER TABLE mission_legs ADD COLUMN created_at REAL NOT NULL DEFAULT 0")
        try db.exec("ALTER TABLE mission_legs ADD COLUMN updated_at REAL NOT NULL DEFAULT 0")

        let missionColumns = try db.query("PRAGMA table_info(missions)")
            .compactMap { $0["name"] as? String }
        guard !missionColumns.isEmpty else { return }
        let missions = try db.query("""
        SELECT id, state, setup_checkpoint, attention_reason, created_at, updated_at
        FROM missions
        """)
        for mission in missions {
            guard let id = mission["id"] as? String,
                  let legacyState = mission["state"] as? String,
                  let checkpoint = mission["setup_checkpoint"] as? String,
                  let createdAt = date(from: mission["created_at"]),
                  let updatedAt = date(from: mission["updated_at"])
            else { throw Error.malformedRecord }
            let migration = try Self.legacyLegMigration(
                state: legacyState,
                checkpoint: checkpoint,
                updatedAt: updatedAt
            )
            try db.exec("""
            UPDATE mission_legs
            SET state = ?, setup_checkpoint = ?, attention_reason = ?, readiness_evidence = ?,
                created_at = ?, updated_at = ?
            WHERE mission_id = ?
            """, bindings: [
                migration.legState.rawValue,
                checkpoint,
                mission["attention_reason"] as? String,
                try migration.readinessEvidence.map(encoder.encode),
                createdAt.timeIntervalSince1970,
                updatedAt.timeIntervalSince1970,
                id,
            ])
            if migration.missionState != legacyState {
                try db.exec("UPDATE missions SET state = ? WHERE id = ?", bindings: [migration.missionState, id])
            }
        }
    }

    private func migrateToV5() throws {
        try db.exec("ALTER TABLE mission_legs ADD COLUMN prepared_initial_prompt TEXT NOT NULL DEFAULT ''")
        let columns = try db.query("PRAGMA table_info(mission_legs)")
            .compactMap { $0["name"] as? String }
        if columns.contains("pending_initial_prompt") {
            try db.exec("""
            UPDATE mission_legs
            SET prepared_initial_prompt = pending_initial_prompt
            WHERE prepared_initial_prompt = '' AND pending_initial_prompt IS NOT NULL
            """)
        }
    }

    private func migrateToV6() throws {
        let tableNames = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'")
            .compactMap { $0["name"] as? String }
        guard tableNames.contains("missions") else { return }

        try db.exec("ALTER TABLE missions RENAME TO missions_v5")
        try db.exec("ALTER TABLE mission_legs RENAME TO mission_legs_v5")
        try db.exec("ALTER TABLE mission_events RENAME TO mission_events_v5")

        try db.exec("DROP INDEX IF EXISTS missions_state_updated_idx")
        try db.exec("DROP INDEX IF EXISTS mission_legs_project_idx")
        try db.exec("DROP INDEX IF EXISTS mission_legs_worktree_idx")
        try db.exec("DROP INDEX IF EXISTS mission_events_mission_created_idx")

        try db.exec("""
        CREATE TABLE missions (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          state TEXT NOT NULL,
          setup_checkpoint TEXT NOT NULL,
          primary_leg_id TEXT NOT NULL,
          attention_reason TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          completed_at REAL
        )
        """)
        try db.exec("""
        CREATE TABLE mission_legs (
          id TEXT PRIMARY KEY,
          mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL,
          project_id TEXT NOT NULL,
          base_ref TEXT NOT NULL,
          branch TEXT NOT NULL,
          destination_path TEXT NOT NULL,
          worktree_id TEXT,
          agent_id TEXT NOT NULL,
          acp_session_id TEXT,
          initial_prompt_id TEXT NOT NULL,
          pending_initial_prompt TEXT,
          review_identity BLOB,
          base_remote_name TEXT,
          worktree_lineage_id TEXT,
          state TEXT NOT NULL DEFAULT 'creating',
          setup_checkpoint TEXT NOT NULL DEFAULT 'creatingWorktree',
          attention_reason TEXT,
          readiness_evidence BLOB,
          created_at REAL NOT NULL DEFAULT 0,
          updated_at REAL NOT NULL DEFAULT 0,
          prepared_initial_prompt TEXT NOT NULL DEFAULT '',
          UNIQUE(mission_id, ordinal)
        )
        """)
        try db.exec("""
        CREATE TABLE mission_events (
          id TEXT PRIMARY KEY,
          mission_id TEXT NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
          leg_id TEXT,
          kind TEXT NOT NULL,
          message TEXT NOT NULL,
          created_at REAL NOT NULL
        )
        """)
        try db.exec("""
        CREATE TABLE mission_sources (
          mission_id TEXT PRIMARY KEY REFERENCES missions(id) ON DELETE CASCADE,
          provider_id TEXT NOT NULL,
          stable_id TEXT NOT NULL,
          canonical_url TEXT NOT NULL,
          provider_label TEXT NOT NULL,
          display_reference TEXT,
          repository_locator BLOB,
          title TEXT NOT NULL,
          body TEXT NOT NULL,
          provider_state TEXT NOT NULL,
          labels BLOB NOT NULL,
          assignees BLOB NOT NULL,
          provider_updated_at REAL,
          captured_at REAL NOT NULL,
          refresh_error TEXT,
          content_origin TEXT NOT NULL,
          is_editable INTEGER NOT NULL,
          is_refreshable INTEGER NOT NULL
        )
        """)

        try db.exec("""
        INSERT INTO missions (
          id, title, state, setup_checkpoint, primary_leg_id,
          attention_reason, created_at, updated_at, completed_at
        )
        SELECT id, title, state, setup_checkpoint, primary_leg_id,
               attention_reason, created_at, updated_at, completed_at
        FROM missions_v5
        """)
        try db.exec("""
        INSERT INTO mission_legs (
          id, mission_id, ordinal, project_id, base_ref, branch, destination_path,
          worktree_id, agent_id, acp_session_id, initial_prompt_id,
          pending_initial_prompt, review_identity, base_remote_name, worktree_lineage_id,
          state, setup_checkpoint, attention_reason, readiness_evidence, created_at,
          updated_at, prepared_initial_prompt
        )
        SELECT id, mission_id, ordinal, project_id, base_ref, branch, destination_path,
               worktree_id, agent_id, acp_session_id, initial_prompt_id,
               pending_initial_prompt, review_identity, base_remote_name, worktree_lineage_id,
               state, setup_checkpoint, attention_reason, readiness_evidence, created_at,
               updated_at, prepared_initial_prompt
        FROM mission_legs_v5
        """)
        try db.exec("""
        INSERT INTO mission_events (id, mission_id, leg_id, kind, message, created_at)
        SELECT id, mission_id, leg_id, kind, message, created_at
        FROM mission_events_v5
        """)

        let legacySources = try db.query("SELECT * FROM mission_issue_sources ORDER BY mission_id")
        for row in legacySources {
            guard let missionID = row["mission_id"] as? String else { throw Error.malformedRecord }
            try insertSource(
                MissionSourceSnapshot(issue: try decodeIssue(row)),
                missionID: MissionID(rawValue: missionID)
            )
        }

        try validateV6MigrationCounts()

        try db.exec("DROP TABLE mission_issue_sources")
        try db.exec("DROP TABLE mission_events_v5")
        try db.exec("DROP TABLE mission_legs_v5")
        try db.exec("DROP TABLE missions_v5")

        try db.exec("CREATE INDEX mission_sources_identity_idx ON mission_sources(provider_id, stable_id)")
        try db.exec("CREATE INDEX missions_state_updated_idx ON missions(state, updated_at)")
        try db.exec("CREATE INDEX mission_legs_project_idx ON mission_legs(project_id)")
        try db.exec("CREATE INDEX mission_legs_worktree_idx ON mission_legs(worktree_id)")
        try db.exec("CREATE INDEX mission_events_mission_created_idx ON mission_events(mission_id, created_at)")
    }

    private func validateV6MigrationCounts() throws {
        let comparisons = [
            ("missions", "missions_v5"),
            ("mission_legs", "mission_legs_v5"),
            ("mission_events", "mission_events_v5"),
            ("mission_sources", "missions_v5"),
        ]
        for (newTable, oldTable) in comparisons {
            let newCount = try rowCount(newTable)
            let oldCount = try rowCount(oldTable)
            guard newCount == oldCount else { throw Error.malformedRecord }
        }
        let orphanCount = try db.query("""
        SELECT (
          (SELECT COUNT(*) FROM mission_sources AS source
           LEFT JOIN missions ON missions.id = source.mission_id WHERE missions.id IS NULL)
          +
          (SELECT COUNT(*) FROM mission_legs AS leg
           LEFT JOIN missions ON missions.id = leg.mission_id WHERE missions.id IS NULL)
          +
          (SELECT COUNT(*) FROM mission_events AS event
           LEFT JOIN missions ON missions.id = event.mission_id WHERE missions.id IS NULL)
        ) AS count
        """).first?["count"] as? Int64
        guard orphanCount == 0 else { throw Error.malformedRecord }
        let missingPrimaryLegs = try db.query("""
        SELECT COUNT(*) AS count
        FROM missions
        LEFT JOIN mission_legs AS leg
          ON leg.id = missions.primary_leg_id AND leg.mission_id = missions.id
        WHERE leg.id IS NULL
        """).first?["count"] as? Int64
        guard missingPrimaryLegs == 0,
              try db.query("PRAGMA foreign_key_check").isEmpty
        else { throw Error.malformedRecord }
    }

    private func rowCount(_ table: String) throws -> Int64 {
        guard let count = try db.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"] as? Int64 else {
            throw Error.malformedRecord
        }
        return count
    }

    private func immediateTransaction<T>(_ work: () throws -> T) throws -> T {
        try db.exec("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try db.exec("COMMIT")
            return result
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    private func validate(_ aggregate: MissionAggregate) throws {
        guard !aggregate.legs.isEmpty,
              aggregate.primaryLeg != nil
        else { throw Error.invalidLegCollection }
        let legIDs = Set(aggregate.legs.map(\.id))
        let projectIDs = Set(aggregate.legs.map(\.projectId))
        guard legIDs.count == aggregate.legs.count,
              projectIDs.count == aggregate.legs.count,
              aggregate.legs.allSatisfy({ $0.missionID == aggregate.mission.id }),
              Set(aggregate.legs.map(\.ordinal)).count == aggregate.legs.count,
              aggregate.legs.map(\.ordinal).sorted() == Array(0 ..< aggregate.legs.count)
        else {
            if projectIDs.count != aggregate.legs.count { throw Error.duplicateLegProject }
            throw Error.invalidLegCollection
        }
        for event in aggregate.events {
            try validate(event: event, for: aggregate.mission.id)
            if let legID = event.legID, !legIDs.contains(legID) { throw Error.invalidEventLeg }
        }
    }

    private func validate(event: MissionEvent, for missionID: MissionID, legID: MissionLegID? = nil) throws {
        guard event.missionID == missionID else { throw Error.invalidEvent }
        if let legID, event.legID != legID { throw Error.invalidEventLeg }
    }

    private func requireMission(_ id: MissionID) throws {
        let rows = try db.query("SELECT id FROM missions WHERE id = ?", bindings: [id.rawValue])
        guard !rows.isEmpty else { throw Error.missionNotFound }
    }

    private func requireAggregate(_ id: MissionID) throws -> MissionAggregate {
        guard let aggregate = try aggregate(id: id) else { throw Error.missionNotFound }
        return aggregate
    }

    private static func legState(
        for missionState: MissionState,
        checkpoint: MissionSetupCheckpoint
    ) -> MissionLegState {
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
            checkpoint == .running ? .running : .creating
        }
    }

    private static func legacyLegMigration(
        state: String,
        checkpoint: String,
        updatedAt: Date
    ) throws -> (missionState: String, legState: MissionLegState, readinessEvidence: MissionLegReadinessEvidence?) {
        guard let missionState = MissionState(rawValue: state),
              let setupCheckpoint = MissionSetupCheckpoint(rawValue: checkpoint)
        else { throw Error.malformedRecord }
        let legState = legState(for: missionState, checkpoint: setupCheckpoint)
        let normalizedMissionState = missionState == .needsAttention ? MissionState.running.rawValue : state
        let readinessEvidence = missionState == .readyToComplete
            ? MissionLegReadinessEvidence(kind: .legacy, observedAt: updatedAt)
            : nil
        return (normalizedMissionState, legState, readinessEvidence)
    }

    private static func globalMissionState(for legs: [MissionLeg]) -> MissionState {
        if legs.allSatisfy({ $0.readinessEvidence != nil }) { return .readyToComplete }
        if legs.allSatisfy({ $0.state == .creating }) { return .creating }
        return .running
    }

    private func updateMissionState(
        missionID: MissionID,
        legs: [MissionLeg],
        updatedAt: Date
    ) throws {
        try db.exec("UPDATE missions SET state = ?, updated_at = ? WHERE id = ? AND state != ?", bindings: [
            Self.globalMissionState(for: legs).rawValue,
            updatedAt.timeIntervalSince1970,
            missionID.rawValue,
            MissionState.completed.rawValue,
        ])
    }

    private func replacing(_ leg: MissionLeg, in legs: [MissionLeg]) -> [MissionLeg] {
        legs.map { $0.id == leg.id ? leg : $0 }
    }

    private func applyLegacyPresentation(to aggregate: inout MissionAggregate) {
        guard let primaryLeg = aggregate.primaryLeg else { return }
        let legacySetup = aggregate.legs.count == 1
            && primaryLeg.state == .creating
            && aggregate.mission.state != .creating
        if aggregate.mission.state != .completed {
            let legacyAttention = aggregate.mission.state == .needsAttention
            // Preserve the one-leg presentation contract while callers migrate
            // from Mission-owned setup state. Multi-leg setup is leg-owned, so
            // an isolated secondary failure must not take the aggregate out of
            // its running state.
            if !legacySetup {
                aggregate.mission.state = (aggregate.legs.count == 1 && legacyAttention)
                    ? .needsAttention
                    : Self.globalMissionState(for: aggregate.legs)
            }
        }
        if !legacySetup {
            aggregate.mission.setupCheckpoint = primaryLeg.setupCheckpoint
            aggregate.mission.attentionReason = primaryLeg.attentionReason
        }
    }

    private func source(missionID: MissionID) throws -> MissionSourceSnapshot {
        let rows = try db.query(
            "SELECT * FROM mission_sources WHERE mission_id = ?",
            bindings: [missionID.rawValue]
        )
        guard let row = rows.first else { throw Error.malformedRecord }
        return try decodeSource(row)
    }

    private static func isAllowedCodeHostRedirect(
        from stored: MissionSourceSnapshot,
        to replacement: MissionSourceSnapshot
    ) -> Bool {
        guard stored.identity.providerID == replacement.identity.providerID,
              stored.identity.providerID == .github || stored.identity.providerID == .gitlab,
              let oldLocator = stored.repositoryLocator,
              let newLocator = replacement.repositoryLocator,
              oldLocator.provider == newLocator.provider,
              oldLocator.host.caseInsensitiveCompare(newLocator.host) == .orderedSame,
              oldLocator.repositorySlug.caseInsensitiveCompare(newLocator.repositorySlug) != .orderedSame,
              stored.displayReference == replacement.displayReference
        else { return false }
        return true
    }

    private func migrateReviewIdentities(
        missionID: MissionID,
        from oldIdentity: MissionRepositoryLocator,
        to newIdentity: MissionRepositoryLocator
    ) throws {
        let rows = try db.query(
            "SELECT id, review_identity FROM mission_legs WHERE mission_id = ?",
            bindings: [missionID.rawValue]
        )
        for row in rows {
            guard let legID = row["id"] as? String,
                  let data = row["review_identity"] as? Data,
                  let review = try? decoder.decode(MissionReviewIdentity.self, from: data),
                  review.provider == oldIdentity.provider,
                  review.host.caseInsensitiveCompare(oldIdentity.host) == .orderedSame,
                  review.repositorySlug.caseInsensitiveCompare(oldIdentity.repositorySlug) == .orderedSame
            else { continue }
            let migrated = MissionReviewIdentity(
                provider: newIdentity.provider,
                host: newIdentity.host,
                repositorySlug: newIdentity.repositorySlug,
                number: review.number,
                url: review.url
            )
            try db.exec(
                "UPDATE mission_legs SET review_identity = ? WHERE id = ? AND mission_id = ?",
                bindings: [try encoder.encode(migrated), legID, missionID.rawValue]
            )
        }
    }

    private func insertMission(_ mission: MissionRecord, initialLeg: MissionLeg) throws {
        let usesLegacyMissionSetup = initialLeg.state == .creating && mission.state != .creating
        let state = usesLegacyMissionSetup ? mission.state : Self.globalMissionState(for: [initialLeg])
        let checkpoint = usesLegacyMissionSetup ? mission.setupCheckpoint : initialLeg.setupCheckpoint
        let attentionReason = usesLegacyMissionSetup ? mission.attentionReason : initialLeg.attentionReason
        try db.exec("""
        INSERT INTO missions (
            id, title, state, setup_checkpoint, primary_leg_id,
            attention_reason, created_at, updated_at, completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            mission.id.rawValue,
            mission.title,
            state.rawValue,
            checkpoint.rawValue,
            mission.primaryLegID.rawValue,
            attentionReason,
            mission.createdAt.timeIntervalSince1970,
            mission.updatedAt.timeIntervalSince1970,
            mission.completedAt?.timeIntervalSince1970,
        ])
    }

    private func insertSource(_ source: MissionSourceSnapshot, missionID: MissionID) throws {
        try db.exec("""
        INSERT INTO mission_sources (
            mission_id, provider_id, stable_id, canonical_url, provider_label,
            display_reference, repository_locator, title, body, provider_state,
            labels, assignees, provider_updated_at, captured_at, refresh_error,
            content_origin, is_editable, is_refreshable
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [missionID.rawValue] + sourceBindings(source))
    }

    private func sourceBindings(_ source: MissionSourceSnapshot) throws -> [Any?] {
        [
            source.identity.providerID.rawValue,
            source.identity.stableID,
            source.canonicalURL.absoluteString,
            source.providerLabel,
            source.displayReference,
            try source.repositoryLocator.map(encoder.encode),
            source.title,
            source.body,
            source.state.rawValue,
            try encoder.encode(source.labels),
            try encoder.encode(source.assignees),
            source.providerUpdatedAt?.timeIntervalSince1970,
            source.capturedAt.timeIntervalSince1970,
            source.refreshError,
            source.contentOrigin.rawValue,
            source.isEditable ? 1 : 0,
            source.isRefreshable ? 1 : 0,
        ]
    }

    private func insertLeg(_ leg: MissionLeg) throws {
        try db.exec("""
        INSERT INTO mission_legs (
            id, mission_id, ordinal, project_id, base_ref, base_remote_name, branch, destination_path,
            worktree_id, worktree_lineage_id, agent_id, acp_session_id, initial_prompt_id,
            prepared_initial_prompt, pending_initial_prompt, review_identity, state, setup_checkpoint,
            attention_reason, readiness_evidence, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            leg.id.rawValue,
            leg.missionID.rawValue,
            leg.ordinal,
            leg.projectId,
            leg.baseRef,
            leg.baseRemoteName,
            leg.branch,
            leg.destinationPath,
            leg.worktreeId,
            leg.worktreeLineageID,
            leg.agentId,
            leg.acpSessionId,
            leg.initialPromptId.uuidString,
            leg.preparedInitialPrompt,
            leg.pendingInitialPrompt,
            try leg.reviewIdentity.map(encoder.encode),
            leg.state.rawValue,
            leg.setupCheckpoint.rawValue,
            leg.attentionReason,
            try leg.readinessEvidence.map(encoder.encode),
            leg.createdAt.timeIntervalSince1970,
            leg.updatedAt.timeIntervalSince1970,
        ])
    }

    private func updateLegRecord(_ leg: MissionLeg) throws {
        let changed = try db.execChanges("""
        UPDATE mission_legs
        SET base_remote_name = ?, worktree_id = ?, worktree_lineage_id = ?, agent_id = ?, acp_session_id = ?,
            pending_initial_prompt = ?, review_identity = ?, state = ?, setup_checkpoint = ?,
            attention_reason = ?, readiness_evidence = ?, updated_at = ?
        WHERE id = ? AND mission_id = ?
        """, bindings: [
            leg.baseRemoteName,
            leg.worktreeId,
            leg.worktreeLineageID,
            leg.agentId,
            leg.acpSessionId,
            leg.pendingInitialPrompt,
            try leg.reviewIdentity.map(encoder.encode),
            leg.state.rawValue,
            leg.setupCheckpoint.rawValue,
            leg.attentionReason,
            try leg.readinessEvidence.map(encoder.encode),
            leg.updatedAt.timeIntervalSince1970,
            leg.id.rawValue,
            leg.missionID.rawValue,
        ])
        guard changed == 1 else { throw Error.missionNotFound }
    }

    private func insertEvent(_ event: MissionEvent) throws {
        try db.exec("""
        INSERT INTO mission_events (id, mission_id, leg_id, kind, message, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """, bindings: [
            event.id,
            event.missionID.rawValue,
            event.legID?.rawValue,
            event.kind.rawValue,
            event.message,
            event.createdAt.timeIntervalSince1970,
        ])
    }

    private func decodeMission(_ row: [String: Any?]) throws -> MissionRecord {
        guard let id = row["id"] as? String,
              let stateRaw = row["state"] as? String,
              let state = MissionState(rawValue: stateRaw),
              let checkpointRaw = row["setup_checkpoint"] as? String,
              let checkpoint = MissionSetupCheckpoint(rawValue: checkpointRaw),
              let primaryLegID = row["primary_leg_id"] as? String,
              let createdAt = date(from: row["created_at"]),
              let updatedAt = date(from: row["updated_at"] as Any?)
        else { throw Error.malformedRecord }
        return .init(
            id: MissionID(rawValue: id),
            title: row["title"] as? String ?? "",
            state: state,
            setupCheckpoint: checkpoint,
            primaryLegID: MissionLegID(rawValue: primaryLegID),
            attentionReason: row["attention_reason"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: date(from: row["completed_at"])
        )
    }

    private func decodeSource(_ row: [String: Any?]) throws -> MissionSourceSnapshot {
        guard let providerID = row["provider_id"] as? String,
              let stableID = row["stable_id"] as? String,
              let canonicalURLRaw = row["canonical_url"] as? String,
              let canonicalURL = URL(string: canonicalURLRaw),
              let providerLabel = row["provider_label"] as? String,
              let stateRaw = row["provider_state"] as? String,
              let state = MissionSourceState(rawValue: stateRaw),
              let labelsData = row["labels"] as? Data,
              let labels = try? decoder.decode([String].self, from: labelsData),
              let assigneesData = row["assignees"] as? Data,
              let assignees = try? decoder.decode([String].self, from: assigneesData),
              let capturedAt = date(from: row["captured_at"]),
              let contentOriginRaw = row["content_origin"] as? String,
              let contentOrigin = MissionSourceContentOrigin(rawValue: contentOriginRaw),
              let isEditable = row["is_editable"] as? Int64,
              let isRefreshable = row["is_refreshable"] as? Int64
        else { throw Error.malformedRecord }
        let repositoryLocator: MissionRepositoryLocator?
        if let data = row["repository_locator"] as? Data {
            guard let decoded = try? decoder.decode(MissionRepositoryLocator.self, from: data) else {
                throw Error.malformedRecord
            }
            repositoryLocator = decoded
        } else {
            repositoryLocator = nil
        }
        return .init(
            identity: .init(
                providerID: MissionSourceProviderID(rawValue: providerID),
                stableID: stableID
            ),
            canonicalURL: canonicalURL,
            providerLabel: providerLabel,
            displayReference: row["display_reference"] as? String,
            repositoryLocator: repositoryLocator,
            title: row["title"] as? String ?? "",
            body: row["body"] as? String ?? "",
            state: state,
            labels: labels,
            assignees: assignees,
            providerUpdatedAt: date(from: row["provider_updated_at"]),
            capturedAt: capturedAt,
            refreshError: row["refresh_error"] as? String,
            contentOrigin: contentOrigin,
            isEditable: isEditable != 0,
            isRefreshable: isRefreshable != 0
        )
    }

    private func decodeIssue(_ row: [String: Any?]) throws -> MissionIssueSnapshot {
        guard let providerRaw = row["provider"] as? String,
              let provider = CodeHostKind(rawValue: providerRaw),
              let host = row["host"] as? String,
              let repositorySlug = row["repository_slug"] as? String,
              let number = row["issue_number"] as? Int64,
              let canonicalURLRaw = row["canonical_url"] as? String,
              let canonicalURL = URL(string: canonicalURLRaw),
              let stateRaw = row["provider_state"] as? String,
              let state = MissionIssueState(rawValue: stateRaw),
              let labelsData = row["labels"] as? Data,
              let labels = try? decoder.decode([String].self, from: labelsData),
              let assigneesData = row["assignees"] as? Data,
              let assignees = try? decoder.decode([String].self, from: assigneesData),
              let capturedAt = date(from: row["captured_at"])
        else { throw Error.malformedRecord }
        return .init(
            identity: .init(provider: provider, host: host, repositorySlug: repositorySlug, number: Int(number)),
            canonicalURL: canonicalURL,
            title: row["title"] as? String ?? "",
            body: row["body"] as? String ?? "",
            state: state,
            labels: labels,
            assignees: assignees,
            providerUpdatedAt: date(from: row["provider_updated_at"]),
            capturedAt: capturedAt,
            refreshError: row["refresh_error"] as? String
        )
    }

    private func decodeLeg(_ row: [String: Any?]) throws -> MissionLeg {
        guard let id = row["id"] as? String,
              let missionID = row["mission_id"] as? String,
              let ordinal = row["ordinal"] as? Int64,
              let initialPromptIDRaw = row["initial_prompt_id"] as? String,
              let initialPromptID = UUID(uuidString: initialPromptIDRaw),
              let stateRaw = row["state"] as? String,
              let state = MissionLegState(rawValue: stateRaw),
              let checkpointRaw = row["setup_checkpoint"] as? String,
              let setupCheckpoint = MissionSetupCheckpoint(rawValue: checkpointRaw),
              let createdAt = date(from: row["created_at"]),
              let updatedAt = date(from: row["updated_at"])
        else { throw Error.malformedRecord }
        let reviewIdentity: MissionReviewIdentity?
        if let reviewData = row["review_identity"] as? Data {
            guard let decoded = try? decoder.decode(MissionReviewIdentity.self, from: reviewData) else {
                throw Error.malformedRecord
            }
            reviewIdentity = decoded
        } else {
            reviewIdentity = nil
        }
        let readinessEvidence: MissionLegReadinessEvidence?
        if let readinessData = row["readiness_evidence"] as? Data {
            guard let decoded = try? decoder.decode(MissionLegReadinessEvidence.self, from: readinessData) else {
                throw Error.malformedRecord
            }
            readinessEvidence = decoded
        } else {
            readinessEvidence = nil
        }
        return .init(
            id: MissionLegID(rawValue: id),
            missionID: MissionID(rawValue: missionID),
            ordinal: Int(ordinal),
            projectId: row["project_id"] as? String ?? "",
            baseRef: row["base_ref"] as? String ?? "",
            baseRemoteName: row["base_remote_name"] as? String,
            branch: row["branch"] as? String ?? "",
            destinationPath: row["destination_path"] as? String ?? "",
            worktreeId: row["worktree_id"] as? String,
            worktreeLineageID: row["worktree_lineage_id"] as? String,
            agentId: row["agent_id"] as? String ?? "",
            acpSessionId: row["acp_session_id"] as? String,
            initialPromptId: initialPromptID,
            preparedInitialPrompt: row["prepared_initial_prompt"] as? String,
            pendingInitialPrompt: row["pending_initial_prompt"] as? String,
            reviewIdentity: reviewIdentity,
            state: state,
            setupCheckpoint: setupCheckpoint,
            attentionReason: row["attention_reason"] as? String,
            readinessEvidence: readinessEvidence,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decodeEvent(_ row: [String: Any?]) throws -> MissionEvent {
        guard let id = row["id"] as? String,
              let missionID = row["mission_id"] as? String,
              let kindRaw = row["kind"] as? String,
              let kind = MissionEventKind(rawValue: kindRaw),
              let message = row["message"] as? String,
              let createdAt = date(from: row["created_at"] as Any?)
        else { throw Error.malformedRecord }
        return .init(
            id: id,
            missionID: MissionID(rawValue: missionID),
            legID: (row["leg_id"] as? String).map(MissionLegID.init(rawValue:)),
            kind: kind,
            message: message,
            createdAt: createdAt
        )
    }

    private func date(from value: Any?) -> Date? {
        if let value = value as? Double { return Date(timeIntervalSince1970: value) }
        if let value = value as? Int64 { return Date(timeIntervalSince1970: TimeInterval(value)) }
        return nil
    }
}
