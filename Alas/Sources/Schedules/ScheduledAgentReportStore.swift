import Foundation

actor ScheduledAgentReportStore {
    static let maximumPayloadBytes = ScheduledAgentReportLimits.maximumPayloadBytes

    private let database: SQLiteDatabase

    private let ownerInstanceID: String
    private let ownerPID: Int64
    private let ownerCreatedAt: Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        path: String = Paths.scheduledAgentReportsDB.path,
        instanceID: String = UUID().uuidString,
        pid: Int64 = Int64(ProcessInfo.processInfo.processIdentifier),
        ownerCreatedAt: Date = Date()
    ) throws {
        self.ownerInstanceID = instanceID
        self.ownerPID = pid
        self.ownerCreatedAt = ownerCreatedAt

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(path: path)
        try Self.immediateTransaction(database) {
            try database.exec("""
            CREATE TABLE IF NOT EXISTS scheduled_agent_reports (
                id TEXT PRIMARY KEY NOT NULL,
                occurrence_id TEXT NOT NULL,
                schedule_id TEXT NOT NULL,
                project_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                session_id TEXT,
                task_state TEXT NOT NULL,
                cleanup_state TEXT NOT NULL,
                payload BLOB NOT NULL,
                owner_instance_id TEXT,
                owner_pid INTEGER,
                owner_created_at REAL
            )
            """)
            let columns = try database.query("PRAGMA table_info(scheduled_agent_reports)")
            let names = Set(columns.compactMap { $0["name"] as? String })
            if !names.contains("owner_instance_id") {
                try database.exec("ALTER TABLE scheduled_agent_reports ADD COLUMN owner_instance_id TEXT")
            }
            if !names.contains("owner_pid") {
                try database.exec("ALTER TABLE scheduled_agent_reports ADD COLUMN owner_pid INTEGER")
            }
            if !names.contains("owner_created_at") {
                try database.exec("ALTER TABLE scheduled_agent_reports ADD COLUMN owner_created_at REAL")
            }
            try database.exec("CREATE INDEX IF NOT EXISTS scheduled_agent_reports_project_date ON scheduled_agent_reports(project_id, started_at DESC)")
            try database.exec("CREATE INDEX IF NOT EXISTS scheduled_agent_reports_schedule_date ON scheduled_agent_reports(schedule_id, started_at DESC)")
            try database.exec("CREATE INDEX IF NOT EXISTS scheduled_agent_reports_occurrence ON scheduled_agent_reports(occurrence_id)")
        }
        self.database = database
    }

    func create(_ report: ScheduledAgentReport) throws {
        guard report.taskState == .running, report.finishedAt == nil else {
            throw ScheduledAgentReportStoreError.invalidInitialState
        }
        try validate(report)
        let payload = try encoder.encode(report)
        let changes = try database.execChanges("""
        INSERT OR IGNORE INTO scheduled_agent_reports (
            id, occurrence_id, schedule_id, project_id, started_at,
            session_id, task_state, cleanup_state, payload,
            owner_instance_id, owner_pid, owner_created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bindings: bindings(for: report, payload: payload) + [
            ownerInstanceID, ownerPID, ownerCreatedAt.timeIntervalSince1970,
        ])
        guard changes == 1 else { throw ScheduledAgentReportStoreError.duplicateReport(report.id) }
    }

    func report(id: String) throws -> ScheduledAgentReport? {
        let rows = try database.query(
            "SELECT payload FROM scheduled_agent_reports WHERE id = ? LIMIT 1",
            bindings: [id]
        )
        return try rows.first.map(decodeReport)
    }

    func page(
        projectID: String,
        scheduleID: String? = nil,
        offset: Int,
        limit: Int
    ) throws -> [ScheduledAgentReport] {
        precondition(offset >= 0)
        precondition(limit > 0)
        let sql: String
        let values: [Any?]
        if let scheduleID {
            sql = """
            SELECT payload FROM scheduled_agent_reports
            WHERE project_id = ? AND schedule_id = ?
            ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?
            """
            values = [projectID, scheduleID, limit, offset]
        } else {
            sql = """
            SELECT payload FROM scheduled_agent_reports
            WHERE project_id = ?
            ORDER BY started_at DESC, id DESC LIMIT ? OFFSET ?
            """
            values = [projectID, limit, offset]
        }
        return try database.query(sql, bindings: values).map(decodeReport)
    }

    func associateWorktree(
        reportID: String,
        worktreeID: String,
        branch: String,
        baseCommit: String
    ) throws {
        var report = try requireRunning(reportID)
        guard report.worktreeID == nil else {
            throw ScheduledAgentReportStoreError.worktreeAlreadyAssociated(reportID)
        }
        report = ScheduledAgentReport(
            id: report.id,
            occurrenceID: report.occurrenceID,
            scheduleID: report.scheduleID,
            scheduleName: report.scheduleName,
            projectID: report.projectID,
            projectName: report.projectName,
            branch: branch,
            baseCommit: baseCommit,
            worktreeID: worktreeID,
            sessionID: report.sessionID,
            agentID: report.agentID,
            modelID: report.modelID,
            request: report.request,
            scriptRun: report.scriptRun,
            startedAt: report.startedAt,
            taskState: report.taskState,
            completion: report.completion,
            cleanupRequested: report.cleanupRequested,
            cleanupState: report.cleanupState,
            cleanupReason: report.cleanupReason
        )
        try persist(report, requireCurrentState: .running)
    }

    func associateScriptRun(
        reportID: String,
        scriptRun: RunScheduleFiring.RunReference
    ) throws {
        var report = try requireRunning(reportID)
        guard report.scriptRun == nil else {
            throw ScheduledAgentReportStoreError.scriptRunAlreadyAssociated(reportID)
        }
        report.scriptRun = scriptRun
        try persist(report, requireCurrentState: .running)
    }

    func recordCompletion(
        reportID: String,
        authenticatedSessionID: String,
        completion: ScheduledAgentCompletion
    ) throws {
        var report = try requireRunning(reportID)
        guard let sessionID = report.sessionID, sessionID == authenticatedSessionID else {
            throw ScheduledAgentReportStoreError.sessionMismatch(reportID)
        }
        guard report.completion == nil else {
            throw ScheduledAgentReportStoreError.completionAlreadyRecorded(reportID)
        }
        try Self.validate(completion)
        report.completion = completion
        try persist(report, requireCurrentState: .running)
    }

    @discardableResult
    func finishRecordedCompletion(
        reportID: String,
        authenticatedSessionID: String,
        at finishedAt: Date = Date()
    ) throws -> ScheduledAgentReport {
        var report = try requireRunning(reportID)
        guard let sessionID = report.sessionID, sessionID == authenticatedSessionID else {
            throw ScheduledAgentReportStoreError.sessionMismatch(reportID)
        }
        guard let completion = report.completion else {
            throw ScheduledAgentReportStoreError.completionNotRecorded(reportID)
        }
        report.finishedAt = finishedAt
        switch completion.outcome {
        case .succeeded:
            report.taskState = .succeeded
        case .failed:
            report.taskState = .failed
        case .needsAttention:
            report.taskState = .needsAttention
        }
        if report.cleanupRequested {
            if report.taskState == .succeeded {
                report.cleanupState = .pending
            } else {
                report.cleanupState = .retained
                report.cleanupReason = "The agent did not report success."
            }
        }
        try persist(report, requireCurrentState: .running)
        return report
    }

    @discardableResult
    func finish(
        reportID: String,
        authenticatedSessionID: String,
        completion: ScheduledAgentCompletion,
        at finishedAt: Date = Date()
    ) throws -> ScheduledAgentReport {
        try recordCompletion(
            reportID: reportID,
            authenticatedSessionID: authenticatedSessionID,
            completion: completion
        )
        return try finishRecordedCompletion(
            reportID: reportID,
            authenticatedSessionID: authenticatedSessionID,
            at: finishedAt
        )
    }

    func associateSession(reportID: String, sessionID: String) throws {
        let report = try requireRunning(reportID)
        guard report.sessionID == nil else {
            throw ScheduledAgentReportStoreError.sessionAlreadyAssociated(reportID)
        }
        var updated = report
        updated.sessionID = sessionID
        try persist(updated, requireCurrentState: .running)
    }

    @discardableResult
    func finishWithoutCompletion(
        reportID: String,
        state: ScheduledAgentTaskState,
        reason: String,
        at finishedAt: Date = Date()
    ) throws -> ScheduledAgentReport {
        guard state == .failed || state == .needsAttention || state == .interrupted else {
            throw ScheduledAgentReportStoreError.invalidTransition(reportID)
        }
        var report = try requireRunning(reportID)
        try Self.validateText(reason)
        report.taskState = state
        report.finishedAt = finishedAt
        if report.cleanupRequested {
            report.cleanupState = .retained
            report.cleanupReason = reason
        }
        try persist(report, requireCurrentState: .running)
        return report
    }

    @discardableResult
    func updateCleanup(
        reportID: String,
        state: ScheduledAgentCleanupState,
        reason: String? = nil
    ) throws -> ScheduledAgentReport {
        guard var report = try self.report(id: reportID) else {
            throw ScheduledAgentReportStoreError.reportNotFound(reportID)
        }
        guard report.cleanupRequested, report.taskState == .succeeded else {
            throw ScheduledAgentReportStoreError.invalidTransition(reportID)
        }
        switch (report.cleanupState, state) {
        case (.notRequested, .pending), (.pending, .removed), (.pending, .retained), (.pending, .failed):
            break
        default:
            throw ScheduledAgentReportStoreError.invalidTransition(reportID)
        }
        if state == .retained || state == .failed {
            guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScheduledAgentReportStoreError.cleanupReasonRequired
            }
            try Self.validateText(reason)
            report.cleanupReason = reason
        } else {
            report.cleanupReason = nil
        }
        report.cleanupState = state
        try persist(report, requireCurrentState: nil)
        return report
    }

    /// Recover incomplete reports only after their recorded owner process is
    /// gone. Legacy rows without ownership metadata are treated as orphans.
    @discardableResult
    func reconcileAfterRestart(at now: Date = Date()) throws -> Int {
        try Self.immediateTransaction(database) {
            let rows = try database.query("""
            SELECT payload, owner_instance_id, owner_pid, owner_created_at
            FROM scheduled_agent_reports
            """)
            var changed = 0
            for row in rows {
                var report = try decodeReport(row)
                let needsRecovery = report.taskState == .running
                    || report.cleanupState == .pending
                    || (report.cleanupRequested
                        && report.taskState == .interrupted
                        && report.cleanupState != .retained)
                guard needsRecovery, !Self.rowHasLiveOwner(row) else { continue }
                var needsWrite = false
                if report.taskState == .running {
                    report.taskState = .interrupted
                    report.finishedAt = now
                    needsWrite = true
                }
                if report.cleanupState == .pending {
                    report.cleanupState = .retained
                    report.cleanupReason = "Alas restarted before cleanup finished; inspect the worktree before removing it."
                    needsWrite = true
                } else if report.cleanupRequested,
                          report.taskState == .interrupted,
                          report.cleanupState != .retained {
                    report.cleanupState = .retained
                    report.cleanupReason = "Alas restarted before the agent completed."
                    needsWrite = true
                }
                guard needsWrite else { continue }
                try persist(report, requireCurrentState: nil)
                changed += 1
            }
            return changed
        }
    }

    func delete(id: String) throws -> Bool {
        guard let report = try self.report(id: id) else { return false }
        guard report.taskState != .running, report.cleanupState != .pending else {
            throw ScheduledAgentReportStoreError.reportNotSettled(id)
        }
        return try database.execChanges("DELETE FROM scheduled_agent_reports WHERE id = ?", bindings: [id]) == 1
    }

    private func requireRunning(_ id: String) throws -> ScheduledAgentReport {
        guard let report = try self.report(id: id) else {
            throw ScheduledAgentReportStoreError.reportNotFound(id)
        }
        guard report.taskState == .running, report.finishedAt == nil else {
            throw ScheduledAgentReportStoreError.invalidTransition(id)
        }
        return report
    }

    private func persist(
        _ report: ScheduledAgentReport,
        requireCurrentState: ScheduledAgentTaskState?
    ) throws {
        try validate(report)
        let payload = try encoder.encode(report)
        let sql: String
        let values: [Any?]
        if let requireCurrentState {
            sql = """
            UPDATE scheduled_agent_reports
            SET occurrence_id = ?, schedule_id = ?, project_id = ?, started_at = ?,
                session_id = ?, task_state = ?, cleanup_state = ?, payload = ?
            WHERE id = ? AND task_state = ?
            """
            values = [
                report.occurrenceID, report.scheduleID, report.projectID,
                report.startedAt.timeIntervalSince1970, report.sessionID,
                report.taskState.rawValue, report.cleanupState.rawValue, payload,
                report.id, requireCurrentState.rawValue,
            ]
        } else {
            sql = """
            UPDATE scheduled_agent_reports
            SET occurrence_id = ?, schedule_id = ?, project_id = ?, started_at = ?,
                session_id = ?, task_state = ?, cleanup_state = ?, payload = ?
            WHERE id = ?
            """
            values = [
                report.occurrenceID, report.scheduleID, report.projectID,
                report.startedAt.timeIntervalSince1970, report.sessionID,
                report.taskState.rawValue, report.cleanupState.rawValue, payload, report.id,
            ]
        }
        let changes = try database.execChanges(sql, bindings: values)
        guard changes == 1 else { throw ScheduledAgentReportStoreError.invalidTransition(report.id) }
    }

    private func bindings(for report: ScheduledAgentReport, payload: Data) -> [Any?] {
        [
            report.id, report.occurrenceID, report.scheduleID, report.projectID,
            report.startedAt.timeIntervalSince1970, report.sessionID,
            report.taskState.rawValue, report.cleanupState.rawValue, payload,
        ]
    }

    private func decodeReport(_ row: [String: Any?]) throws -> ScheduledAgentReport {
        guard let payload = row["payload"] as? Data else {
            throw ScheduledAgentReportStoreError.invalidRow
        }
        return try decoder.decode(ScheduledAgentReport.self, from: payload)
    }

    /// Serialize schema upgrades and recovery scans across app processes.
    /// A reserved write lock prevents two readers from racing into DDL or updates.
    private static func immediateTransaction<T>(
        _ database: SQLiteDatabase,
        _ work: () throws -> T
    ) throws -> T {
        try database.exec("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try database.exec("COMMIT")
            return result
        } catch {
            try? database.exec("ROLLBACK")
            throw error
        }
    }

    private static func rowHasLiveOwner(_ row: [String: Any?]) -> Bool {
        guard let instanceID = row["owner_instance_id"] as? String,
              !instanceID.isEmpty,
              let pid = row["owner_pid"] as? Int64,
              pid > 0,
              let timestamp = row["owner_created_at"] as? Double,
              timestamp.isFinite,
              timestamp >= 0,
              timestamp <= Date().timeIntervalSince1970 + 1 else {
            return false
        }
        return ACPProcessLiveness.pidMatchesLease(
            pid: pid,
            createdAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func validate(_ report: ScheduledAgentReport) throws {
        guard report.id.utf8.count <= 128,
              report.occurrenceID.utf8.count <= 128,
              report.scheduleID.utf8.count <= 128,
              report.projectID.utf8.count <= 128,
              report.agentID.utf8.count <= 128 else {
            throw ScheduledAgentReportStoreError.identifierTooLong
        }
        try Self.validateText(report.scheduleName)
        try Self.validateText(report.projectName)
        try Self.validateText(report.request)
        if let reason = report.cleanupReason { try Self.validateText(reason) }
        if let completion = report.completion { try Self.validate(completion) }
        let data = try encoder.encode(report)
        guard data.count <= Self.maximumPayloadBytes else {
            throw ScheduledAgentReportStoreError.payloadTooLarge(data.count)
        }
    }

    private static func validate(_ completion: ScheduledAgentCompletion) throws {
        try validateText(completion.summary)
        guard completion.checks.count <= ScheduledAgentReportLimits.maximumItems,
              completion.links.count <= ScheduledAgentReportLimits.maximumItems else {
            throw ScheduledAgentReportStoreError.tooManyReportItems
        }
        for check in completion.checks {
            try validateText(check.name)
            try validateText(check.result)
        }
        for link in completion.links {
            try validateText(link.label)
            try validateText(link.url)
        }
        let textBytes = completion.checks.reduce(completion.summary.utf8.count) {
            $0 + $1.name.utf8.count + $1.result.utf8.count
        } + completion.links.reduce(0) {
            $0 + $1.label.utf8.count + $1.url.utf8.count
        }
        guard textBytes <= ScheduledAgentReportLimits.maximumTextBytes else {
            throw ScheduledAgentReportStoreError.payloadTooLarge(textBytes)
        }
        let bytes = try JSONEncoder().encode(completion).count
        guard bytes <= maximumPayloadBytes else {
            throw ScheduledAgentReportStoreError.payloadTooLarge(bytes)
        }
    }

    private static func validateText(_ text: String) throws {
        guard text.utf8.count <= ScheduledAgentReportLimits.maximumTextBytes else {
            throw ScheduledAgentReportStoreError.payloadTooLarge(text.utf8.count)
        }
    }
}

enum ScheduledAgentReportStoreError: Error, Equatable, Sendable {
    case invalidInitialState
    case duplicateReport(String)
    case reportNotFound(String)
    case invalidTransition(String)
    case worktreeAlreadyAssociated(String)
    case sessionAlreadyAssociated(String)
    case sessionMismatch(String)
    case cleanupReasonRequired
    case scriptRunAlreadyAssociated(String)
    case completionAlreadyRecorded(String)
    case completionNotRecorded(String)
    case identifierTooLong
    case tooManyReportItems
    case payloadTooLarge(Int)
    case reportNotSettled(String)
    case invalidRow
}
