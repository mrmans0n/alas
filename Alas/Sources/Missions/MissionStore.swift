import Foundation

final class MissionStore {
    enum Error: Swift.Error, Equatable {
        case exactlyOneLeg
        case duplicateActiveIssueIdentity
        case issueIdentityChanged
        case malformedRecord
        case missionNotFound
        case invalidEvent
    }

    static let targetSchemaVersion = 3

    let path: String
    let db: SQLiteDatabase

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
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

            try insertMission(aggregate.mission)
            try insertIssue(aggregate.issue, missionID: aggregate.mission.id)
            try insertLeg(aggregate.legs[0])
            for event in aggregate.events { try insertEvent(event) }
        }
    }

    func aggregate(id: MissionID) throws -> MissionAggregate? {
        let rows = try db.query("SELECT * FROM missions WHERE id = ?", bindings: [id.rawValue])
        guard let missionRow = rows.first else { return nil }
        let mission = try decodeMission(missionRow)
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
        let aggregate = MissionAggregate(
            mission: mission,
            issue: try decodeIssue(issueRow),
            legs: legs,
            events: events
        )
        try validate(aggregate)
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

    func updateSetup(
        id: MissionID,
        state: MissionState,
        checkpoint: MissionSetupCheckpoint,
        attentionReason: String?,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: id)
        try immediateTransaction {
            try requireMission(id)
            try db.exec("""
            UPDATE missions
            SET state = ?, setup_checkpoint = ?, attention_reason = ?, updated_at = ?
            WHERE id = ?
            """, bindings: [
                state.rawValue,
                checkpoint.rawValue,
                attentionReason,
                event.createdAt.timeIntervalSince1970,
                id.rawValue,
            ])
            try insertEvent(event)
        }
    }

    func updateLeg(_ leg: MissionLeg, event: MissionEvent?) throws {
        if let event { try validate(event: event, for: leg.missionID) }
        try immediateTransaction {
            let changed = try db.execChanges("""
            UPDATE mission_legs
            SET base_remote_name = ?, worktree_id = ?, worktree_creation_epoch = ?, agent_id = ?, acp_session_id = ?,
                pending_initial_prompt = ?, review_identity = ?
            WHERE id = ? AND mission_id = ?
            """, bindings: [
                leg.baseRemoteName,
                leg.worktreeId,
                leg.worktreeCreationEpoch,
                leg.agentId,
                leg.acpSessionId,
                leg.pendingInitialPrompt,
                try leg.reviewIdentity.map(encoder.encode),
                leg.id.rawValue,
                leg.missionID.rawValue,
            ])
            guard changed == 1 else { throw Error.missionNotFound }
            if let event {
                try db.exec("UPDATE missions SET updated_at = ? WHERE id = ?", bindings: [
                    event.createdAt.timeIntervalSince1970,
                    leg.missionID.rawValue,
                ])
                try insertEvent(event)
            }
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
        try validate(event: event, for: id)
        guard leg.missionID == id else { throw Error.malformedRecord }
        try immediateTransaction {
            try requireMission(id)
            let changed = try db.execChanges("""
            UPDATE mission_legs
            SET base_remote_name = ?, worktree_id = ?, worktree_creation_epoch = ?, agent_id = ?, acp_session_id = ?,
                pending_initial_prompt = ?, review_identity = ?
            WHERE id = ? AND mission_id = ?
            """, bindings: [
                leg.baseRemoteName,
                leg.worktreeId,
                leg.worktreeCreationEpoch,
                leg.agentId,
                leg.acpSessionId,
                leg.pendingInitialPrompt,
                try leg.reviewIdentity.map(encoder.encode),
                leg.id.rawValue,
                leg.missionID.rawValue,
            ])
            guard changed == 1 else { throw Error.missionNotFound }
            try db.exec("""
            UPDATE missions
            SET state = ?, setup_checkpoint = ?, attention_reason = ?, updated_at = ?
            WHERE id = ?
            """, bindings: [
                state.rawValue,
                checkpoint.rawValue,
                attentionReason,
                event.createdAt.timeIntervalSince1970,
                id.rawValue,
            ])
            try insertEvent(event)
        }
    }

    func replaceIssueSnapshot(
        missionID: MissionID,
        snapshot: MissionIssueSnapshot,
        event: MissionEvent
    ) throws {
        try validate(event: event, for: missionID)
        try immediateTransaction {
            try requireMission(missionID)
            let storedIdentity = try issueIdentity(missionID: missionID)
            guard Self.sameIssue(storedIdentity, snapshot.identity) else {
                throw Error.issueIdentityChanged
            }
            let snapshot = Self.snapshot(snapshot, preserving: storedIdentity)
            let changed = try db.execChanges("""
            UPDATE mission_issue_sources
            SET provider = ?, host = ?, repository_slug = ?, issue_number = ?,
                canonical_url = ?, title = ?, body = ?, provider_state = ?, labels = ?,
                assignees = ?, provider_updated_at = ?, captured_at = ?, refresh_error = ?
            WHERE mission_id = ?
            """, bindings: issueBindings(snapshot) + [missionID.rawValue])
            guard changed == 1 else { throw Error.malformedRecord }
            try db.exec("UPDATE missions SET title = ?, updated_at = ? WHERE id = ?", bindings: [
                snapshot.title,
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
            let rows = try db.query("SELECT primary_leg_id FROM missions WHERE id = ?", bindings: [id.rawValue])
            guard let primaryLegID = rows.first?["primary_leg_id"] as? String else { throw Error.missionNotFound }
            let changed = try db.execChanges(
                "UPDATE mission_legs SET review_identity = ? WHERE id = ? AND mission_id = ?",
                bindings: [try reviewIdentity.map(encoder.encode), primaryLegID, id.rawValue]
            )
            guard changed == 1 else { throw Error.malformedRecord }
            try db.exec("""
            UPDATE missions
            SET state = ?, setup_checkpoint = ?, attention_reason = NULL, updated_at = ?
            WHERE id = ?
            """, bindings: [
                MissionState.readyToComplete.rawValue,
                MissionSetupCheckpoint.running.rawValue,
                event.createdAt.timeIntervalSince1970,
                id.rawValue,
            ])
            try insertEvent(event)
        }
    }

    func complete(id: MissionID, leg: MissionLeg? = nil, at: Date, event: MissionEvent) throws {
        try validate(event: event, for: id)
        if let leg, leg.missionID != id { throw Error.malformedRecord }
        try immediateTransaction {
            try requireMission(id)
            if let leg {
                let changed = try db.execChanges("""
                UPDATE mission_legs
                SET worktree_creation_epoch = ?
                WHERE id = ? AND mission_id = ?
                """, bindings: [
                    leg.worktreeCreationEpoch,
                    leg.id.rawValue,
                    id.rawValue,
                ])
                guard changed == 1 else { throw Error.missionNotFound }
            }
            try db.exec("""
            UPDATE missions
            SET state = ?, attention_reason = NULL, updated_at = ?, completed_at = ?
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
        if current < 1 {
            try migrate(to: 1, migrateToV1)
            current = 1
        }
        if current < 2 {
            try migrate(to: 2, migrateToV2)
            current = 2
        }
        if current < 3 {
            try migrate(to: 3, migrateToV3)
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
        try db.exec("ALTER TABLE mission_legs ADD COLUMN worktree_creation_epoch INTEGER")
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
        guard aggregate.legs.count == 1,
              let leg = aggregate.primaryLeg,
              leg.missionID == aggregate.mission.id
        else { throw Error.exactlyOneLeg }
        for event in aggregate.events { try validate(event: event, for: aggregate.mission.id) }
    }

    private func validate(event: MissionEvent, for missionID: MissionID) throws {
        guard event.missionID == missionID else { throw Error.invalidEvent }
    }

    private func requireMission(_ id: MissionID) throws {
        let rows = try db.query("SELECT id FROM missions WHERE id = ?", bindings: [id.rawValue])
        guard !rows.isEmpty else { throw Error.missionNotFound }
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

    private func insertMission(_ mission: MissionRecord) throws {
        try db.exec("""
        INSERT INTO missions (
            id, title, source_kind, state, setup_checkpoint, primary_leg_id,
            attention_reason, created_at, updated_at, completed_at
        ) VALUES (?, ?, 'issue', ?, ?, ?, ?, ?, ?, ?)
        """, bindings: [
            mission.id.rawValue,
            mission.title,
            mission.state.rawValue,
            mission.setupCheckpoint.rawValue,
            mission.primaryLegID.rawValue,
            mission.attentionReason,
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
            worktree_id, worktree_creation_epoch, agent_id, acp_session_id, initial_prompt_id,
            pending_initial_prompt, review_identity
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            leg.worktreeCreationEpoch,
            leg.agentId,
            leg.acpSessionId,
            leg.initialPromptId.uuidString,
            leg.pendingInitialPrompt,
            try leg.reviewIdentity.map(encoder.encode),
        ])
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
              let initialPromptID = UUID(uuidString: initialPromptIDRaw)
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
            worktreeCreationEpoch: row["worktree_creation_epoch"] as? Int64,
            agentId: row["agent_id"] as? String ?? "",
            acpSessionId: row["acp_session_id"] as? String,
            initialPromptId: initialPromptID,
            pendingInitialPrompt: row["pending_initial_prompt"] as? String,
            reviewIdentity: reviewIdentity
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
