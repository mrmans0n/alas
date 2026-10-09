import Foundation

/// What the tab bar's run activity pill reads: the selected worktree's runs.
struct RunActivityInput: Equatable, Sendable {
    var records: [RunRecord] = []
    /// Undismissed failures, the same ones the failure banner shows.
    var failures: [RunScriptFailure] = []
    /// Script keys whose run tab still has a live shell to show.
    var liveTerminalKeys: Set<String> = []
}

/// Pure decision for the activity pill and its run list.
struct RunActivityPresentation: Equatable {
    enum Pill: Equatable, Sendable {
        case none
        case starting(scriptKey: String, name: String)
        case running(scriptKey: String, name: String, startedAt: Date)
        case runningMany(count: Int)
        case succeeded(name: String, duration: TimeInterval)
        case failed(failureID: String, runID: String, name: String, exitCode: Int32)
    }

    enum RowAction: Hashable, Sendable {
        case output, restart, stop, report, rerun

        var title: String {
            switch self {
            case .output:  "Output"
            case .restart: "Restart"
            case .stop:    "Stop"
            case .report:  "Report"
            case .rerun:   "Rerun"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        enum Kind: Equatable {
            case starting
            case running
            case failed(exitCode: Int32)
        }

        let runID: String
        let scriptKey: String
        let name: String
        let kind: Kind
        /// Start time for active runs, completion time for failures.
        let since: Date
        let actions: [RowAction]

        var id: String { runID }
    }

    /// How long a success stays on the pill.
    static let successLinger: TimeInterval = 4

    let pill: Pill
    /// A failure is waiting while runs are active; the pill marks it.
    let hasUndismissedFailure: Bool
    let rows: [Row]
    /// When the pill changes without new input: the end of a success linger.
    let expiresAt: Date?

    static func make(input: RunActivityInput, now: Date) -> RunActivityPresentation {
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

        var expiresAt: Date?
        let pill: Pill
        switch active.count {
        case 0:
            if let failure = failures.first {
                pill = .failed(failureID: failure.id, runID: failure.runID, name: failure.scriptName, exitCode: failure.exitCode)
            } else if let success = recentSuccess(in: input.records, now: now) {
                pill = .succeeded(name: success.record.scriptName, duration: success.finishedAt.timeIntervalSince(success.record.startedAt))
                expiresAt = success.finishedAt.addingTimeInterval(successLinger)
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
            rows: activeRows + failureRows,
            expiresAt: expiresAt
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
}
