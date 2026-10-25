import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Bounded output retained with a completed run. `unavailable` means Alas
/// observed an outcome but could not read its transcript; it must never be
/// presented as an empty successful log.
public enum RunHistoryOutput: Equatable, Sendable {
    case available(text: String, truncated: Bool)
    case unavailable
}

/// Immutable durable snapshot of one completed command.
public struct RunHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let scriptKey: String
    public let scriptName: String
    public let worktreeID: String
    public let branch: String
    public let target: RunExecutionTarget
    public let endpoint: URL?
    public let outcome: RunOutcome
    public let startedAt: Date
    public let finishedAt: Date
    public let portConflict: RunPortConflict?
    public let output: RunHistoryOutput

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public var summary: RunHistorySummary {
        RunHistorySummary(
            id: id,
            scriptKey: scriptKey,
            scriptName: scriptName,
            worktreeID: worktreeID,
            branch: branch,
            target: target,
            endpoint: endpoint,
            outcome: outcome,
            startedAt: startedAt,
            finishedAt: finishedAt,
            portConflict: portConflict
        )
    }

    public init(id: String, scriptKey: String, scriptName: String, worktreeID: String, branch: String, target: RunExecutionTarget, endpoint: URL?, outcome: RunOutcome, startedAt: Date, finishedAt: Date, portConflict: RunPortConflict?, output: RunHistoryOutput) {
        self.id = id
        self.scriptKey = scriptKey
        self.scriptName = scriptName
        self.worktreeID = worktreeID
        self.branch = branch
        self.target = target
        self.endpoint = endpoint
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.portConflict = portConflict
        self.output = output
    }
}

/// The display/query shape for History pages. Transcript text intentionally
/// stays out of this type so a page never materializes up to 20 MiB of output.
public struct RunHistorySummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let scriptKey: String
    public let scriptName: String
    public let worktreeID: String
    public let branch: String
    public let target: RunExecutionTarget
    public let endpoint: URL?
    public let outcome: RunOutcome
    public let startedAt: Date
    public let finishedAt: Date
    public let portConflict: RunPortConflict?

    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    public init(id: String, scriptKey: String, scriptName: String, worktreeID: String, branch: String, target: RunExecutionTarget, endpoint: URL?, outcome: RunOutcome, startedAt: Date, finishedAt: Date, portConflict: RunPortConflict?) {
        self.id = id
        self.scriptKey = scriptKey
        self.scriptName = scriptName
        self.worktreeID = worktreeID
        self.branch = branch
        self.target = target
        self.endpoint = endpoint
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.portConflict = portConflict
    }
}

public struct RunHistoryPage: Equatable, Sendable {
    public let entries: [RunHistorySummary]
    public let totalCount: Int

    public init(entries: [RunHistorySummary], totalCount: Int) {
        self.entries = entries
        self.totalCount = totalCount
    }
}

/// Durable completed-run history. Active run state stays in `RunRecordStore`;
/// this store only receives immutable records that already reached an observed
/// terminal outcome.
public actor RunHistoryStore {
    public static let defaultMaximumEntriesPerWorktree = 100

    private let database: SQLiteDatabase
    private let maximumEntriesPerWorktree: Int
    /// Off the cooperative pool: SQLite blocks its thread for every statement.
    private nonisolated let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(
        path: String = Paths.runHistoryDB.path,
        maximumEntriesPerWorktree: Int = 100
    ) throws {
        precondition(maximumEntriesPerWorktree > 0)
        queue = DispatchSerialQueue(label: "io.nlopez.alas.run-history \(path)")
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
    public func append(_ entry: RunHistoryEntry) throws -> Bool {
        try database.transaction {
            let changes = try database.execChanges("""
            INSERT OR IGNORE INTO run_history (
                run_id, script_key, script_name, worktree_id, branch,
                target_host, target_working_directory, endpoint,
                outcome, exit_code, started_at, finished_at,
                conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name,
                output_kind, output_text, output_truncated
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: entry.bindings)
            guard changes == 1 else { return false }

            try database.exec("""
            DELETE FROM run_history
            WHERE run_id IN (
                SELECT run_id FROM run_history
                WHERE worktree_id = ?
                ORDER BY finished_at DESC, run_id DESC
                LIMIT -1 OFFSET ?
            )
            """, bindings: [entry.worktreeID, maximumEntriesPerWorktree])
            return true
        }
    }

    public func page(worktreeID: String, offset: Int, limit: Int) throws -> RunHistoryPage {
        precondition(offset >= 0)
        precondition(limit > 0)
        let total = try totalCount(worktreeID: worktreeID)
        let rows = try database.query("""
        SELECT run_id, script_key, script_name, worktree_id, branch,
               target_host, target_working_directory, endpoint,
               outcome, exit_code, started_at, finished_at,
               conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name
        FROM run_history
        WHERE worktree_id = ?
        ORDER BY finished_at DESC, run_id DESC
        LIMIT ? OFFSET ?
        """, bindings: [worktreeID, limit, offset])
        return RunHistoryPage(entries: try rows.map(decodeSummary), totalCount: total)
    }

    public func entry(id: String) throws -> RunHistoryEntry? {
        let rows = try database.query("""
        SELECT run_id, script_key, script_name, worktree_id, branch,
               target_host, target_working_directory, endpoint,
               outcome, exit_code, started_at, finished_at,
               conflict_kind, conflict_worktree_id, conflict_branch, conflict_script_name,
               output_kind, output_text, output_truncated
        FROM run_history
        WHERE run_id = ?
        LIMIT 1
        """, bindings: [id])
        return try rows.first.map(decodeEntry)
    }

    public func clear(worktreeID: String) throws {
        try database.exec("DELETE FROM run_history WHERE worktree_id = ?", bindings: [worktreeID])
    }

    public func clear(worktreeID: String, finishedOnOrBefore cutoff: Date) throws {
        try database.exec(
            "DELETE FROM run_history WHERE worktree_id = ? AND finished_at <= ?",
            bindings: [worktreeID, cutoff.timeIntervalSince1970]
        )
    }

    public func purge(worktreeID: String) throws {
        try clear(worktreeID: worktreeID)
    }

    public func ids(worktreeID: String) throws -> Set<String> {
        let rows = try database.query(
            "SELECT run_id FROM run_history WHERE worktree_id = ?",
            bindings: [worktreeID]
        )
        return Set(try rows.map { try string("run_id", in: $0) })
    }

    private func totalCount(worktreeID: String) throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS count FROM run_history WHERE worktree_id = ?",
            bindings: [worktreeID]
        )
        return Int((rows.first?["count"] as? Int64) ?? 0)
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS run_history (
            run_id TEXT PRIMARY KEY,
            script_key TEXT NOT NULL,
            script_name TEXT NOT NULL,
            worktree_id TEXT NOT NULL,
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
        try database.exec("""
        CREATE INDEX IF NOT EXISTS run_history_worktree_finished_idx
        ON run_history(worktree_id, finished_at DESC, run_id DESC)
        """)
    }

    private func decodeSummary(_ row: [String: Any?]) throws -> RunHistorySummary {
        RunHistorySummary(
            id: try string("run_id", in: row),
            scriptKey: try string("script_key", in: row),
            scriptName: try string("script_name", in: row),
            worktreeID: try string("worktree_id", in: row),
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
            id, scriptKey, scriptName, worktreeID, branch,
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
