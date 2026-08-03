import Foundation

final class MissionStore {
    enum Error: Swift.Error, Equatable {
        // Temporary source compatibility while callers migrate to the explicit
        // multi-leg validation errors below.
        case exactlyOneLeg
        case duplicateActiveIssueIdentity
        case issueIdentityChanged
        case malformedRecord
        case missionNotFound
        case invalidEvent
        case invalidLegCollection
        case duplicateLegProject
        case invalidEventLeg
    }

    static let targetSchemaVersion = 4

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
                let identity = aggregate.issue.identity
                let duplicate = try db.query("""
                SELECT missions.id
                FROM missions
                JOIN mission_issue_sources ON mission_issue_sources.mission_id = missions.id
                WHERE provider = ? AND host = ? COLLATE NOCASE
                  AND repository_slug = ? COLLATE NOCASE AND issue_number = ?
                  AND state != ?
                LIMIT 1
                """, bindings: [
                    identity.provider.rawValue,
                    identity.host,
                    identity.repositorySlug,
                    identity.number,
                    MissionState.completed.rawValue,
                ])
                if !duplicate.isEmpty { throw Error.duplicateActiveIssueIdentity }
            }

            try insertMission(aggregate.mission, initialLeg: aggregate.legs[0])
            try insertIssue(aggregate.issue, missionID: aggregate.mission.id)
            try insertLeg(aggregate.legs[0])
            for event in aggregate.events { try insertEvent(event) }
        }
    }

    func aggregate(id: MissionID) throws -> MissionAggregate? {
        let rows = try db.query("SELECT * FROM missions WHERE id = ?", bindings: [id.rawValue])
        guard let missionRow = rows.first else { return nil }
        var mission = try decodeMission(missionRow)
        let issueRows = try db.query(
            "SELECT * FROM mission_issue_sources WHERE mission_id = ?",
            bindings: [id.rawValue]
        )
        guard let issueRow = issueRows.first else { throw Error.malformedRecord }
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
            issue: try decodeIssue(issueRow),
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

    func activeMission(issueIdentity: MissionIssueIdentity) throws -> MissionAggregate? {
        let rows = try db.query("""
        SELECT missions.id
        FROM missions
        JOIN mission_issue_sources ON mission_issue_sources.mission_id = missions.id
        WHERE provider = ? AND host = ? COLLATE NOCASE
          AND repository_slug = ? COLLATE NOCASE AND issue_number = ?
          AND state != ?
        ORDER BY updated_at DESC, missions.id ASC
        LIMIT 1
        """, bindings: [
            issueIdentity.provider.rawValue,
            issueIdentity.host,
            issueIdentity.repositorySlug,
            issueIdentity.number,
            MissionState.completed.rawValue,
        ])
        guard let id = rows.first?["id"] as? String else { return nil }
        return try aggregate(id: MissionID(rawValue: id))
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
    func replaceIssueSnapshot(
        missionID: MissionID,
        snapshot: MissionIssueSnapshot,
        event: MissionEvent
    ) throws -> [MissionID] {
        try validate(event: event, for: missionID)
        return try immediateTransaction {
            try requireMission(missionID)
            let storedIdentity = try issueIdentity(missionID: missionID)
            guard Self.sameIssueSource(storedIdentity, snapshot.identity) else {
                throw Error.issueIdentityChanged
            }
            let repositoryRenamed = storedIdentity.repositorySlug.caseInsensitiveCompare(
                snapshot.identity.repositorySlug
            ) != .orderedSame
            if repositoryRenamed,
               try hasActiveIssueIdentityCollision(
                   missionID: missionID,
                   storedIdentity: storedIdentity,
                   replacementIdentity: snapshot.identity
               ) {
                throw Error.duplicateActiveIssueIdentity
            }
            let migratedDuplicateIDs: [MissionID]
            if repositoryRenamed {
                migratedDuplicateIDs = try migrateActiveDuplicateIssueIdentities(
                    excluding: missionID,
                    from: storedIdentity,
                    to: snapshot
                )
            } else {
                migratedDuplicateIDs = []
            }
            let snapshot = repositoryRenamed
                ? snapshot
                : Self.snapshot(snapshot, preserving: storedIdentity)
            let changed = try db.execChanges("""
            UPDATE mission_issue_sources
            SET provider = ?, host = ?, repository_slug = ?, issue_number = ?,
                canonical_url = ?, title = ?, body = ?, provider_state = ?, labels = ?,
                assignees = ?, provider_updated_at = ?, captured_at = ?, refresh_error = ?
            WHERE mission_id = ?
            """, bindings: issueBindings(snapshot) + [missionID.rawValue])
            guard changed == 1 else { throw Error.malformedRecord }
            if repositoryRenamed {
                try migrateReviewIdentities(
                    missionID: missionID,
                    from: storedIdentity,
                    to: snapshot.identity
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

    private func hasActiveIssueIdentityCollision(
        missionID: MissionID,
        storedIdentity: MissionIssueIdentity,
        replacementIdentity: MissionIssueIdentity
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
              JOIN mission_issue_sources AS issue ON issue.mission_id = cohort.id
              WHERE cohort.id != ? AND cohort.state != ?
                AND issue.provider = ? AND issue.host = ? COLLATE NOCASE
                AND issue.repository_slug = ? COLLATE NOCASE AND issue.issue_number = ?
            )
          )
          AND EXISTS (
            SELECT 1
            FROM missions AS duplicate
            JOIN mission_issue_sources AS issue ON issue.mission_id = duplicate.id
            WHERE duplicate.id != ? AND duplicate.state != ?
              AND issue.provider = ? AND issue.host = ? COLLATE NOCASE
              AND issue.repository_slug = ? COLLATE NOCASE AND issue.issue_number = ?
          )
        LIMIT 1
        """, bindings: [
            missionID.rawValue,
            MissionState.completed.rawValue,
            missionID.rawValue,
            MissionState.completed.rawValue,
            storedIdentity.provider.rawValue,
            storedIdentity.host,
            storedIdentity.repositorySlug,
            storedIdentity.number,
            missionID.rawValue,
            MissionState.completed.rawValue,
            replacementIdentity.provider.rawValue,
            replacementIdentity.host,
            replacementIdentity.repositorySlug,
            replacementIdentity.number,
        ])
        return !rows.isEmpty
    }

    private func migrateActiveDuplicateIssueIdentities(
        excluding missionID: MissionID,
        from storedIdentity: MissionIssueIdentity,
        to snapshot: MissionIssueSnapshot
    ) throws -> [MissionID] {
        let duplicateIDs = try db.query("""
        SELECT missions.id
        FROM missions
        JOIN mission_issue_sources AS issue ON issue.mission_id = missions.id
        WHERE missions.id != ? AND missions.state != ?
          AND issue.provider = ? AND issue.host = ? COLLATE NOCASE
          AND issue.repository_slug = ? COLLATE NOCASE AND issue.issue_number = ?
        """, bindings: [
            missionID.rawValue,
            MissionState.completed.rawValue,
            storedIdentity.provider.rawValue,
            storedIdentity.host,
            storedIdentity.repositorySlug,
            storedIdentity.number,
        ]).compactMap { $0["id"] as? String }

        for duplicateID in duplicateIDs {
            let duplicateMissionID = MissionID(rawValue: duplicateID)
            let changed = try db.execChanges("""
            UPDATE mission_issue_sources
            SET provider = ?, host = ?, repository_slug = ?, issue_number = ?, canonical_url = ?
            WHERE mission_id = ?
            """, bindings: [
                snapshot.identity.provider.rawValue,
                snapshot.identity.host,
                snapshot.identity.repositorySlug,
                snapshot.identity.number,
                snapshot.canonicalURL.absoluteString,
                duplicateID,
            ])
            guard changed == 1 else { throw Error.malformedRecord }
            try migrateReviewIdentities(
                missionID: duplicateMissionID,
                from: storedIdentity,
                to: snapshot.identity
            )
        }
        return duplicateIDs.map { MissionID(rawValue: $0) }
    }

    func updateIssueRefreshError(
        missionID: MissionID,
        refreshError: String,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: missionID)
        try immediateTransaction {
            try requireMission(missionID)
            let changed = try db.execChanges(
                "UPDATE mission_issue_sources SET refresh_error = ? WHERE mission_id = ?",
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
            let aggregate = try requireAggregate(id)
            guard aggregate.legs.allSatisfy({ $0.readinessEvidence != nil }) else {
                throw Error.invalidLegCollection
            }
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
        try db.exec("UPDATE missions SET state = ?, updated_at = ? WHERE id = ?", bindings: [
            Self.globalMissionState(for: legs).rawValue,
            updatedAt.timeIntervalSince1970,
            missionID.rawValue,
        ])
    }

    private func replacing(_ leg: MissionLeg, in legs: [MissionLeg]) -> [MissionLeg] {
        legs.map { $0.id == leg.id ? leg : $0 }
    }

    private func applyLegacyPresentation(to aggregate: inout MissionAggregate) {
        guard let primaryLeg = aggregate.primaryLeg else { return }
        if aggregate.mission.state != .completed {
            aggregate.mission.state = Self.globalMissionState(for: aggregate.legs)
        }
        aggregate.mission.setupCheckpoint = primaryLeg.setupCheckpoint
        aggregate.mission.attentionReason = primaryLeg.attentionReason
    }

    private func issueIdentity(missionID: MissionID) throws -> MissionIssueIdentity {
        let rows = try db.query("""
        SELECT provider, host, repository_slug, issue_number
        FROM mission_issue_sources
        WHERE mission_id = ?
        """, bindings: [missionID.rawValue])
        guard let row = rows.first,
              let providerRaw = row["provider"] as? String,
              let provider = CodeHostKind(rawValue: providerRaw),
              let host = row["host"] as? String,
              let repositorySlug = row["repository_slug"] as? String,
              let number = row["issue_number"] as? Int64
        else { throw Error.malformedRecord }
        return .init(provider: provider, host: host, repositorySlug: repositorySlug, number: Int(number))
    }

    private static func sameIssue(_ lhs: MissionIssueIdentity, _ rhs: MissionIssueIdentity) -> Bool {
        lhs.provider == rhs.provider
            && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.repositorySlug.caseInsensitiveCompare(rhs.repositorySlug) == .orderedSame
            && lhs.number == rhs.number
    }

    private static func sameIssueSource(_ lhs: MissionIssueIdentity, _ rhs: MissionIssueIdentity) -> Bool {
        lhs.provider == rhs.provider
            && lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
            && lhs.number == rhs.number
    }

    private func migrateReviewIdentities(
        missionID: MissionID,
        from oldIdentity: MissionIssueIdentity,
        to newIdentity: MissionIssueIdentity
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

    private static func snapshot(
        _ snapshot: MissionIssueSnapshot,
        preserving identity: MissionIssueIdentity
    ) -> MissionIssueSnapshot {
        MissionIssueSnapshot(
            identity: identity,
            canonicalURL: snapshot.canonicalURL,
            title: snapshot.title,
            body: snapshot.body,
            state: snapshot.state,
            labels: snapshot.labels,
            assignees: snapshot.assignees,
            providerUpdatedAt: snapshot.providerUpdatedAt,
            capturedAt: snapshot.capturedAt,
            refreshError: snapshot.refreshError
        )
    }

    private func insertMission(_ mission: MissionRecord, initialLeg: MissionLeg) throws {
        try db.exec("""
        INSERT INTO missions (
            id, title, source_kind, state, setup_checkpoint, primary_leg_id,
            attention_reason, created_at, updated_at, completed_at
        ) VALUES (?, ?, 'issue', ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            mission.id.rawValue,
            mission.title,
            Self.globalMissionState(for: [initialLeg]).rawValue,
            initialLeg.setupCheckpoint.rawValue,
            mission.primaryLegID.rawValue,
            initialLeg.attentionReason,
            mission.createdAt.timeIntervalSince1970,
            mission.updatedAt.timeIntervalSince1970,
            mission.completedAt?.timeIntervalSince1970,
        ])
    }

    private func insertIssue(_ issue: MissionIssueSnapshot, missionID: MissionID) throws {
        try db.exec("""
        INSERT INTO mission_issue_sources (
            mission_id, provider, host, repository_slug, issue_number, canonical_url,
            title, body, provider_state, labels, assignees, provider_updated_at,
            captured_at, refresh_error
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [missionID.rawValue] + issueBindings(issue))
    }

    private func issueBindings(_ issue: MissionIssueSnapshot) throws -> [Any?] {
        [
            issue.identity.provider.rawValue,
            issue.identity.host,
            issue.identity.repositorySlug,
            issue.identity.number,
            issue.canonicalURL.absoluteString,
            issue.title,
            issue.body,
            issue.state.rawValue,
            try encoder.encode(issue.labels),
            try encoder.encode(issue.assignees),
            issue.providerUpdatedAt?.timeIntervalSince1970,
            issue.capturedAt.timeIntervalSince1970,
            issue.refreshError,
        ]
    }

    private func insertLeg(_ leg: MissionLeg) throws {
        try db.exec("""
        INSERT INTO mission_legs (
            id, mission_id, ordinal, project_id, base_ref, base_remote_name, branch, destination_path,
            worktree_id, worktree_lineage_id, agent_id, acp_session_id, initial_prompt_id,
            pending_initial_prompt, review_identity, state, setup_checkpoint, attention_reason,
            readiness_evidence, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
              let updatedAt = date(from: row["updated_at"])
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
              let createdAt = date(from: row["created_at"])
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
