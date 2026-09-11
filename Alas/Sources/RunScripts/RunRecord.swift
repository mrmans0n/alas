import Foundation

/// How a run ended. `unknown` exists so losing sight of a process is never
/// laundered into success: an interrupted run reports only what we observed.
enum RunOutcome: Equatable, Sendable {
    case succeeded
    case failed(exitCode: Int32)
    /// The user stopped the run (or its terminal) while it was still going.
    case stopped
    /// Observation ended before the command reported an exit status.
    case unknown
}

/// Lifecycle of a single command, tracked independently of the terminal shell
/// hosting it — an `alas-on-exit: keep` script leaves its shell at a prompt
/// long after the command itself finished, and closing that shell later says
/// nothing about the command's outcome.
enum RunStatus: Equatable, Sendable {
    case notRun
    case starting
    case running
    case finished(RunOutcome)

    var isActive: Bool {
        switch self {
        case .starting, .running: true
        case .notRun, .finished:  false
        }
    }
}

/// Where a run executes. Rows surface this so a local run and an SSH run of
/// the same script are never mistaken for each other.
struct RunExecutionTarget: Equatable, Sendable {
    /// SSH destination, or nil when the command runs on this Mac.
    let host: String?
    /// Absolute working directory on `host`.
    let workingDirectory: String

    var isRemote: Bool { host != nil }
    var hostLabel: String { host ?? "This Mac" }
}

/// Another owner of a run's endpoint port, detected when the run starts.
/// Alas reports the collision and never terminates the process holding it.
enum RunPortConflict: Equatable, Sendable {
    /// Another run Alas owns already serves the port.
    case ownedByRun(worktreeID: String, branch: String, scriptName: String)
    /// Something outside Alas is listening on it.
    case externalProcess
}

/// The observed history of one launch of one script in one worktree.
struct RunRecord: Identifiable, Equatable, Sendable {
    /// Fresh per launch. Completion monitors carry it so a late callback from
    /// a superseded run is dropped instead of clobbering the run that
    /// replaced it.
    let id: String
    let scriptKey: String
    let scriptName: String
    let worktreeID: String
    let branch: String
    let target: RunExecutionTarget
    let endpoint: URL?
    var status: RunStatus
    var startedAt: Date
    var finishedAt: Date?
    /// Terminal leaf hosting the run, once one exists.
    var sessionID: String?
    /// `RunScriptFailure.id` holding the captured output of a failed run.
    var failureID: String?
    var portConflict: RunPortConflict?

    init(
        id: String,
        scriptKey: String,
        scriptName: String,
        worktreeID: String,
        branch: String,
        target: RunExecutionTarget,
        endpoint: URL? = nil,
        status: RunStatus,
        startedAt: Date,
        finishedAt: Date? = nil,
        sessionID: String? = nil,
        failureID: String? = nil,
        portConflict: RunPortConflict? = nil
    ) {
        self.id = id
        self.scriptKey = scriptKey
        self.scriptName = scriptName
        self.worktreeID = worktreeID
        self.branch = branch
        self.target = target
        self.endpoint = endpoint
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sessionID = sessionID
        self.failureID = failureID
        self.portConflict = portConflict
    }

    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// The latest run per (worktree, script). Keyed by worktree first so tearing
/// a worktree down is one removal and no lookup can reach across worktrees.
///
/// Deliberately a plain value type with no knowledge of terminals: the Run
/// tab, and any future local-checks surface, can share it.
struct RunRecordStore: Equatable {
    private(set) var byWorktree: [String: [String: RunRecord]] = [:]

    func record(worktreeID: String, scriptKey: String) -> RunRecord? {
        byWorktree[worktreeID]?[scriptKey]
    }

    func records(worktreeID: String) -> [RunRecord] {
        Array(byWorktree[worktreeID, default: [:]].values)
    }

    func isCurrentActiveRun(runID: String, worktreeID: String, scriptKey: String) -> Bool {
        guard let record = record(worktreeID: worktreeID, scriptKey: scriptKey) else { return false }
        return record.id == runID && record.status.isActive
    }

    var activeRecords: [RunRecord] {
        byWorktree.values.flatMap(\.values).filter(\.status.isActive)
    }

    /// Starts a run, returning the record it displaced so a launch that fails
    /// before the command exists can put the previous outcome back.
    @discardableResult
    mutating func begin(_ record: RunRecord) -> RunRecord? {
        let previous = byWorktree[record.worktreeID]?[record.scriptKey]
        byWorktree[record.worktreeID, default: [:]][record.scriptKey] = record
        return previous
    }

    /// Undoes a `begin` whose launch never produced a command. A no-op once
    /// something else has taken the slot, so a stale rollback can't resurrect
    /// an old record over a newer run.
    mutating func rollback(runID: String, to previous: RunRecord?) {
        guard let location = locate(runID: runID) else { return }
        byWorktree[location.worktreeID]?[location.scriptKey] = previous
        if byWorktree[location.worktreeID]?.isEmpty == true {
            byWorktree[location.worktreeID] = nil
        }
    }

    mutating func markRunning(runID: String, sessionID: String) {
        mutateActive(runID: runID) {
            $0.status = .running
            $0.sessionID = sessionID
        }
    }

    mutating func finish(runID: String, outcome: RunOutcome, at date: Date, failureID: String? = nil) {
        mutateActive(runID: runID) {
            $0.status = .finished(outcome)
            $0.finishedAt = date
            $0.failureID = failureID
        }
    }

    /// User-initiated stop. Only an in-flight run can be stopped: a command
    /// that already reported an exit status keeps that outcome even when its
    /// shell is closed afterwards.
    mutating func markStopped(worktreeID: String, scriptKey: String, at date: Date) {
        guard let record = record(worktreeID: worktreeID, scriptKey: scriptKey), record.status.isActive else { return }
        mutateActive(runID: record.id) {
            $0.status = .finished(.stopped)
            $0.finishedAt = date
        }
    }

    /// Observation ended without an exit status (terminal killed, SSH dropped,
    /// monitor cancelled). Never resolves to success.
    mutating func markLostObservation(runID: String, at date: Date) {
        mutateActive(runID: runID) {
            $0.status = .finished(.unknown)
            $0.finishedAt = date
        }
    }

    mutating func markLostObservation(worktreeID: String, scriptKey: String, at date: Date) {
        guard let record = record(worktreeID: worktreeID, scriptKey: scriptKey) else { return }
        markLostObservation(runID: record.id, at: date)
    }

    mutating func setPortConflict(_ conflict: RunPortConflict?, runID: String) {
        mutateActive(runID: runID) { $0.portConflict = conflict }
    }

    mutating func purge(worktreeID: String) {
        byWorktree[worktreeID] = nil
    }

    /// The run Alas already owns on `port` at `host`, if any. Used to name the
    /// other side of a port collision instead of guessing.
    func activeRunOwningPort(_ port: Int, host: String?, excludingRunID: String? = nil) -> RunRecord? {
        activeRecords.first { record in
            record.id != excludingRunID
                && record.target.host == host
                && record.endpoint?.runEndpointPort == port
        }
    }

    private func locate(runID: String) -> (worktreeID: String, scriptKey: String)? {
        for (worktreeID, records) in byWorktree {
            for (scriptKey, record) in records where record.id == runID {
                return (worktreeID, scriptKey)
            }
        }
        return nil
    }

    private mutating func mutateActive(runID: String, _ body: (inout RunRecord) -> Void) {
        guard let location = locate(runID: runID),
              var record = byWorktree[location.worktreeID]?[location.scriptKey],
              record.status.isActive
        else { return }
        body(&record)
        byWorktree[location.worktreeID]?[location.scriptKey] = record
    }
}

extension URL {
    /// Explicit port, else the scheme's default. `nil` when neither applies,
    /// which is exactly when a port collision can't be reasoned about.
    var runEndpointPort: Int? {
        if let port { return port }
        switch scheme?.lowercased() {
        case "http":  return 80
        case "https": return 443
        default:      return nil
        }
    }
}
