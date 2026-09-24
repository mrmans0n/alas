import Foundation

/// Bounded output retained with a completed run. `unavailable` means Alas
/// observed an outcome but could not read its transcript; it must never be
/// presented as an empty successful log.
enum RunHistoryOutput: Equatable, Sendable {
    case available(text: String, truncated: Bool)
    case unavailable
}

struct RunHistoryOwner: Hashable, Sendable {
    let worktreeID: String
    let projectId: String?
}

struct RunHistoryReportKey: Hashable, Sendable {
    let owner: RunHistoryOwner
    let runID: String
}

/// Immutable durable snapshot of one completed command.
struct RunHistoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let scriptKey: String
    let scriptName: String
    let worktreeID: String
    /// The owning project; nil only for legacy or otherwise unqualified runs.
    let projectId: String?
    let branch: String
    let target: RunExecutionTarget
    let endpoint: URL?
    let outcome: RunOutcome
    let startedAt: Date
    let finishedAt: Date
    let portConflict: RunPortConflict?
    let output: RunHistoryOutput

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    var summary: RunHistorySummary {
        RunHistorySummary(
            id: id,
            scriptKey: scriptKey,
            scriptName: scriptName,
            worktreeID: worktreeID,
            projectId: projectId,
            branch: branch,
            target: target,
            endpoint: endpoint,
            outcome: outcome,
            startedAt: startedAt,
            finishedAt: finishedAt,
            portConflict: portConflict
        )
    }
}

/// The display/query shape for History pages. Transcript text intentionally
/// stays out of this type so a page never materializes up to 20 MiB of output.
struct RunHistorySummary: Identifiable, Equatable, Sendable {
    let id: String
    let scriptKey: String
    let scriptName: String
    let worktreeID: String
    let projectId: String?
    let branch: String
    let target: RunExecutionTarget
    let endpoint: URL?
    let outcome: RunOutcome
    let startedAt: Date
    let finishedAt: Date
    let portConflict: RunPortConflict?

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

struct RunHistoryPage: Equatable, Sendable {
    let entries: [RunHistorySummary]
    let totalCount: Int
}

/// Durable completed-run history. Active run state stays in `RunRecordStore`;
/// this store only receives immutable records that already reached an observed
/// terminal outcome.
actor RunHistoryStore {
    static let defaultMaximumEntriesPerWorktree = 100

    private let database: SQLiteDatabase
    private let maximumEntriesPerWorktree: Int

    init(
        path: String = Paths.runHistoryDB.path,
        maximumEntriesPerWorktree: Int = 100
    ) throws {
        precondition(maximumEntriesPerWorktree > 0)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try SQLiteDatabase(path: path)
        self.maximumEntriesPerWorktree = maximumEntriesPerWorktree
        try Self.migrate(database)
    }

    /// Returns false when a late lifecycle callback attempts to archive an ID
    /// already retained by an earlier, authoritative settlement.
    @discardableResult
    func append(_ entry: RunHistoryEntry) throws -> Bool {
        try database.transaction {
            if let projectId = entry.projectId {
                try adoptLegacyRows(worktreeID: entry.worktreeID, projectID: projectId)
            }
            let changes = try database.execChanges("""
            INSERT OR IGNORE INTO run_history (
                run_id, script_key, script_name, worktree_id, project_id, branch,
                target_host, target_working_directory, endpoint,
                outcome, exit_code, started_at, finished_at,
                conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name,
                output_kind, output_text, output_truncated
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: entry.bindings)
            guard changes == 1 else { return false }

            try database.exec("""
            DELETE FROM run_history
            WHERE run_id IN (
                SELECT run_id FROM run_history
                WHERE worktree_id = ? AND project_id IS ?
                ORDER BY finished_at DESC, run_id DESC
                LIMIT -1 OFFSET ?
            )
            """, bindings: [entry.worktreeID, entry.projectId, maximumEntriesPerWorktree])
            return true
        }
    }

    func page(worktreeID: String, projectID: String? = nil, offset: Int, limit: Int) throws -> RunHistoryPage {
        precondition(offset >= 0)
        precondition(limit > 0)
        if let projectID { try adoptLegacyRows(worktreeID: worktreeID, projectID: projectID) }
        let total = try totalCount(worktreeID: worktreeID, projectID: projectID)
        let rows: [[String: Any?]]
        if let projectID {
            rows = try database.query("""
            SELECT run_id, script_key, script_name, worktree_id, project_id, branch,
                   target_host, target_working_directory, endpoint,
                   outcome, exit_code, started_at, finished_at,
                   conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name
            FROM run_history
            WHERE worktree_id = ? AND project_id = ?
            ORDER BY finished_at DESC, run_id DESC
            LIMIT ? OFFSET ?
            """, bindings: [worktreeID, projectID, limit, offset])
        } else {
            rows = try database.query("""
            SELECT run_id, script_key, script_name, worktree_id, project_id, branch,
               target_host, target_working_directory, endpoint,
               outcome, exit_code, started_at, finished_at,
               conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name
            FROM run_history
            WHERE worktree_id = ?
            ORDER BY finished_at DESC, run_id DESC
            LIMIT ? OFFSET ?
            """, bindings: [worktreeID, limit, offset])
        }
        return RunHistoryPage(entries: try rows.map(decodeSummary), totalCount: total)
    }

    func entry(id: String, worktreeID: String? = nil, projectID: String? = nil) throws -> RunHistoryEntry? {
        if let worktreeID, let projectID { try adoptLegacyRows(worktreeID: worktreeID, projectID: projectID) }
        let rows: [[String: Any?]]
        if let worktreeID, let projectID {
            rows = try database.query("""
            SELECT run_id, script_key, script_name, worktree_id, project_id, branch,
                   target_host, target_working_directory, endpoint,
                   outcome, exit_code, started_at, finished_at,
                   conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name,
                   output_kind, output_text, output_truncated
            FROM run_history
            WHERE run_id = ? AND worktree_id = ? AND project_id = ?
            LIMIT 1
            """, bindings: [id, worktreeID, projectID])
        } else {
            let worktreeClause = worktreeID == nil ? "" : " AND worktree_id = ?"
            var bindings: [Any?] = [id]
            if let worktreeID { bindings.append(worktreeID) }
            rows = try database.query("""
            SELECT run_id, script_key, script_name, worktree_id, project_id, branch,
               target_host, target_working_directory, endpoint,
               outcome, exit_code, started_at, finished_at,
               conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name,
               output_kind, output_text, output_truncated
            FROM run_history
            WHERE run_id = ?\(worktreeClause)
            LIMIT 1
            """, bindings: bindings)
        }
        return try rows.first.map(decodeEntry)
    }

    func clear(worktreeID: String, projectID: String? = nil) throws {
        if let projectID {
            try adoptLegacyRows(worktreeID: worktreeID, projectID: projectID)
            try database.exec("DELETE FROM run_history WHERE worktree_id = ? AND project_id = ?", bindings: [worktreeID, projectID])
        } else {
            try database.exec("DELETE FROM run_history WHERE worktree_id = ?", bindings: [worktreeID])
        }
    }

    func clear(worktreeID: String, finishedOnOrBefore cutoff: Date, projectID: String? = nil) throws {
        if let projectID { try adoptLegacyRows(worktreeID: worktreeID, projectID: projectID) }
        let projectClause = projectID == nil ? "" : " AND project_id = ?"
        var bindings: [Any?] = [worktreeID, cutoff.timeIntervalSince1970]
        if let projectID { bindings.append(projectID) }
        try database.exec("DELETE FROM run_history WHERE worktree_id = ? AND finished_at <= ?\(projectClause)", bindings: bindings)
    }

    func purge(worktreeID: String, projectID: String? = nil) throws {
        try clear(worktreeID: worktreeID, projectID: projectID)
    }

    func ids(worktreeID: String, projectID: String? = nil) throws -> Set<String> {
        if let projectID { try adoptLegacyRows(worktreeID: worktreeID, projectID: projectID) }
        let projectClause = projectID == nil ? "" : " AND project_id = ?"
        var bindings: [Any?] = [worktreeID]
        if let projectID { bindings.append(projectID) }
        let rows = try database.query("SELECT run_id FROM run_history WHERE worktree_id = ?\(projectClause)", bindings: bindings)
        return Set(try rows.map { try string("run_id", in: $0) })
    }

    private func totalCount(worktreeID: String, projectID: String?) throws -> Int {
        let projectClause = projectID == nil ? "" : " AND project_id = ?"
        var bindings: [Any?] = [worktreeID]
        if let projectID { bindings.append(projectID) }
        let rows = try database.query("SELECT COUNT(*) AS count FROM run_history WHERE worktree_id = ?\(projectClause)", bindings: bindings)
        return Int((rows.first?["count"] as? Int64) ?? 0)
    }

    /// Old history rows predate project identity. The first project to query a
    /// shared worktree adopts those ambiguous rows exactly once, rather than
    /// exposing them in every project's history.
    private func adoptLegacyRows(worktreeID: String, projectID: String) throws {
        try database.exec(
            "UPDATE run_history SET project_id = ? WHERE worktree_id = ? AND project_id IS NULL",
            bindings: [projectID, worktreeID]
        )
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS run_history (
            run_id TEXT PRIMARY KEY,
            script_key TEXT NOT NULL,
            script_name TEXT NOT NULL,
            worktree_id TEXT NOT NULL,
            project_id TEXT,
            branch TEXT NOT NULL,
            target_host TEXT,
            target_working_directory TEXT NOT NULL,
            endpoint TEXT,
            outcome TEXT NOT NULL,
            exit_code INTEGER,
            started_at REAL NOT NULL,
            finished_at REAL NOT NULL,
            conflict_kind TEXT,
            conflict_worktree_id TEXT,
            conflict_branch TEXT,
            conflict_script_name TEXT,
            output_kind TEXT NOT NULL,
            output_text TEXT,
            output_truncated INTEGER NOT NULL DEFAULT 0
        )
        """)
        let columns = try database.query("PRAGMA table_info(run_history)")
        if !columns.contains(where: { $0["name"] as? String == "project_id" }) {
            try database.exec("ALTER TABLE run_history ADD COLUMN project_id TEXT")
        }
        try database.exec("""
        CREATE INDEX IF NOT EXISTS run_history_worktree_finished_idx
        ON run_history(worktree_id, finished_at DESC, run_id DESC)
        """)
        try database.exec("""
        CREATE INDEX IF NOT EXISTS run_history_owner_finished_idx
        ON run_history(worktree_id, project_id, finished_at DESC, run_id DESC)
        """)
    }

    private func decodeSummary(_ row: [String: Any?]) throws -> RunHistorySummary {
        RunHistorySummary(
            id: try string("run_id", in: row),
            scriptKey: try string("script_key", in: row),
            scriptName: try string("script_name", in: row),
            worktreeID: try string("worktree_id", in: row),
            projectId: row["project_id"] as? String,
            branch: try string("branch", in: row),
            target: .init(
                host: row["target_host"] as? String,
                workingDirectory: try string("target_working_directory", in: row)
            ),
            endpoint: (row["endpoint"] as? String).flatMap(URL.init(string:)),
            outcome: try outcome(in: row),
            startedAt: try date("started_at", in: row),
            finishedAt: try date("finished_at", in: row),
            portConflict: conflict(in: row)
        )
    }

    private func decodeEntry(_ row: [String: Any?]) throws -> RunHistoryEntry {
        let summary = try decodeSummary(row)
        return RunHistoryEntry(
            id: summary.id,
            scriptKey: summary.scriptKey,
            scriptName: summary.scriptName,
            worktreeID: summary.worktreeID,
            projectId: summary.projectId,
            branch: summary.branch,
            target: summary.target,
            endpoint: summary.endpoint,
            outcome: summary.outcome,
            startedAt: summary.startedAt,
            finishedAt: summary.finishedAt,
            portConflict: summary.portConflict,
            output: try output(in: row)
        )
    }

    private func string(_ column: String, in row: [String: Any?]) throws -> String {
        guard let value = row[column] as? String else { throw RunHistoryStoreError.invalidRow(column) }
        return value
    }

    private func date(_ column: String, in row: [String: Any?]) throws -> Date {
        guard let value = row[column] as? Double else { throw RunHistoryStoreError.invalidRow(column) }
        return Date(timeIntervalSince1970: value)
    }

    private func outcome(in row: [String: Any?]) throws -> RunOutcome {
        switch try string("outcome", in: row) {
        case "succeeded": return .succeeded
        case "stopped": return .stopped
        case "unknown": return .unknown
        case "failed":
            guard let exitCode = row["exit_code"] as? Int64 else {
                throw RunHistoryStoreError.invalidRow("exit_code")
            }
            return .failed(exitCode: Int32(exitCode))
        case let invalid: throw RunHistoryStoreError.invalidOutcome(invalid)
        }
    }

    private func conflict(in row: [String: Any?]) -> RunPortConflict? {
        switch row["conflict_kind"] as? String {
        case "owned":
            guard let worktreeID = row["conflict_worktree_id"] as? String,
                  let branch = row["conflict_branch"] as? String,
                  let scriptName = row["conflict_script_name"] as? String
            else { return nil }
            return .ownedByRun(worktreeID: worktreeID, branch: branch, scriptName: scriptName)
        case "external": return .externalProcess
        default: return nil
        }
    }

    private func output(in row: [String: Any?]) throws -> RunHistoryOutput {
        switch try string("output_kind", in: row) {
        case "available":
            guard let text = row["output_text"] as? String,
                  let truncated = row["output_truncated"] as? Int64
            else { throw RunHistoryStoreError.invalidRow("output") }
            return .available(text: text, truncated: truncated != 0)
        case "unavailable": return .unavailable
        case let invalid: throw RunHistoryStoreError.invalidOutput(invalid)
        }
    }
}

private extension RunHistoryEntry {
    var bindings: [Any?] {
        let outcomeKind: String
        let exitCode: Int64?
        switch outcome {
        case .succeeded:
            outcomeKind = "succeeded"
            exitCode = nil
        case .stopped:
            outcomeKind = "stopped"
            exitCode = nil
        case .unknown:
            outcomeKind = "unknown"
            exitCode = nil
        case .failed(let code):
            outcomeKind = "failed"
            exitCode = Int64(code)
        }
        let conflictKind: String?
        let conflictWorktreeID: String?
        let conflictBranch: String?
        let conflictScriptName: String?
        switch portConflict {
        case .none:
            conflictKind = nil
            conflictWorktreeID = nil
            conflictBranch = nil
            conflictScriptName = nil
        case .externalProcess:
            conflictKind = "external"
            conflictWorktreeID = nil
            conflictBranch = nil
            conflictScriptName = nil
        case let .ownedByRun(worktreeID, branch, scriptName):
            conflictKind = "owned"
            conflictWorktreeID = worktreeID
            conflictBranch = branch
            conflictScriptName = scriptName
        }
        let outputKind: String
        let outputText: String?
        let outputTruncated: Int64
        switch output {
        case let .available(text, truncated):
            outputKind = "available"
            outputText = text
            outputTruncated = truncated ? 1 : 0
        case .unavailable:
            outputKind = "unavailable"
            outputText = nil
            outputTruncated = 0
        }
        return [
            id, scriptKey, scriptName, worktreeID, projectId, branch,
            target.host, target.workingDirectory, endpoint?.absoluteString,
            outcomeKind, exitCode, startedAt.timeIntervalSince1970, finishedAt.timeIntervalSince1970,
            conflictKind, conflictWorktreeID, conflictBranch, conflictScriptName,
            outputKind, outputText, outputTruncated
        ]
    }
}

private enum RunHistoryStoreError: Error {
    case invalidRow(String)
    case invalidOutcome(String)
    case invalidOutput(String)
}
