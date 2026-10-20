import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// What the tab bar's run activity pill reads: the selected worktree's runs.
public struct RunActivityInput: Equatable, Sendable {
    public var records: [RunRecord] = []
    /// Undismissed failures, the same ones the failure banner shows.
    public var failures: [RunScriptFailure] = []
    /// Script keys whose run tab still has a live shell to show.
    public var liveTerminalKeys: Set<String> = []
    /// Run IDs that have a report to open.
    public var reportRunIDs: Set<String> = []

    public init(records: [RunRecord] = [], failures: [RunScriptFailure] = [], liveTerminalKeys: Set<String> = [], reportRunIDs: Set<String> = []) {
        self.records = records
        self.failures = failures
        self.liveTerminalKeys = liveTerminalKeys
        self.reportRunIDs = reportRunIDs
    }
}

/// Pure decision for the activity pill and its run list.
public struct RunActivityPresentation: Equatable, Sendable {
    public enum Pill: Equatable, Sendable {
        case none
        case starting(scriptKey: String, name: String)
        case running(scriptKey: String, name: String, startedAt: Date)
        case runningMany(count: Int)
        case succeeded(name: String, duration: TimeInterval)
        case failed(failureID: String, runID: String, name: String, exitCode: Int32)
    }

    public enum RowAction: Hashable, Sendable {
        case output, restart, stop, report, rerun

        public var title: String {
            switch self {
            case .output:  "Output"
            case .restart: "Restart"
            case .stop:    "Stop"
            case .report:  "Report"
            case .rerun:   "Rerun"
            }
        }
    }

    public struct Row: Equatable, Identifiable, Sendable {
        public enum Kind: Equatable, Sendable {
            case starting
            case running
            case failed(exitCode: Int32)
            case succeeded(duration: TimeInterval)
        }

        public let runID: String
        public let scriptKey: String
        public let name: String
        public let kind: Kind
        /// Start time for active runs, completion time for finished ones.
        public let since: Date
        public let actions: [RowAction]

        public var id: String { runID }

        public init(runID: String, scriptKey: String, name: String, kind: Kind, since: Date, actions: [RowAction]) {
            self.runID = runID
            self.scriptKey = scriptKey
            self.name = name
            self.kind = kind
            self.since = since
            self.actions = actions
        }
    }

    /// How long a success stays on the pill.
    public static let successLinger: TimeInterval = 4

    public let pill: Pill
    /// A failure is waiting while runs are active; the pill marks it.
    public let hasUndismissedFailure: Bool
    public let rows: [Row]
    /// When the pill changes without new input: the end of a success linger.
    public let expiresAt: Date?

    public static func make(input: RunActivityInput, now: Date) -> RunActivityPresentation {
        let active = input.records
            .filter(\.status.isActive)
            .sorted { $0.startedAt > $1.startedAt }
        let failures = input.failures.sorted { $0.completedAt > $1.completedAt }
        let activeRows = active.map { record in
            Row(
                runID: record.id,
                scriptKey: record.scriptKey,
                name: record.scriptName,
                kind: record.status == .starting ? .starting : .running,
                since: record.startedAt,
                actions: (input.liveTerminalKeys.contains(record.scriptKey) ? [.output] : []) + [.restart, .stop]
            )
        }
        let failureRows = failures.map { failure in
            Row(
                runID: failure.runID,
                scriptKey: failure.scriptKey,
                name: failure.scriptName,
                kind: .failed(exitCode: failure.exitCode),
                since: failure.completedAt,
                actions: [.report, .rerun]
            )
        }

        let success = recentSuccess(in: input.records, now: now)
        let successRows = success.map { success in
            [Row(
                runID: success.record.id,
                scriptKey: success.record.scriptKey,
                name: success.record.scriptName,
                kind: .succeeded(duration: success.finishedAt.timeIntervalSince(success.record.startedAt)),
                since: success.finishedAt,
                actions: (input.reportRunIDs.contains(success.record.id) ? [.report] : []) + [.rerun]
            )]
        } ?? []

        let pill: Pill
        switch active.count {
        case 0:
            if let failure = failures.first {
                pill = .failed(failureID: failure.id, runID: failure.runID, name: failure.scriptName, exitCode: failure.exitCode)
            } else if let success {
                pill = .succeeded(name: success.record.scriptName, duration: success.finishedAt.timeIntervalSince(success.record.startedAt))
            } else {
                pill = .none
            }
        case 1:
            let run = active[0]
            pill = run.status == .starting
                ? .starting(scriptKey: run.scriptKey, name: run.scriptName)
                : .running(scriptKey: run.scriptKey, name: run.scriptName, startedAt: run.startedAt)
        default:
            pill = .runningMany(count: active.count)
        }

        return RunActivityPresentation(
            pill: pill,
            hasUndismissedFailure: !active.isEmpty && !failures.isEmpty,
            rows: activeRows + failureRows + successRows,
            expiresAt: success.map { $0.finishedAt.addingTimeInterval(successLinger) }
        )
    }

    /// The newest finished run, when it succeeded inside the linger window.
    /// A later stop, failure or lost run hides an earlier success.
    private static func recentSuccess(in records: [RunRecord], now: Date) -> (record: RunRecord, finishedAt: Date)? {
        let finished = records.compactMap { record in
            record.finishedAt.map { (record: record, finishedAt: $0) }
        }
        guard let newest = finished.max(by: { $0.finishedAt < $1.finishedAt }),
              newest.record.status == .finished(.succeeded),
              now < newest.finishedAt.addingTimeInterval(successLinger)
        else { return nil }
        return newest
    }

    public init(pill: Pill, hasUndismissedFailure: Bool, rows: [Row], expiresAt: Date?) {
        self.pill = pill
        self.hasUndismissedFailure = hasUndismissedFailure
        self.rows = rows
        self.expiresAt = expiresAt
    }
}
