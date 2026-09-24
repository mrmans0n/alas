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
    /// The project that launched this run; a path-derived worktree ID can be shared.
    let projectId: String?
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
        projectId: String?,
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
        self.projectId = projectId
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

/// The latest run per (project, worktree, script). Keep the project dimension
/// because different projects can expose the same path-derived worktree ID.
///
/// Deliberately a plain value type with no knowledge of terminals: the Run
/// tab, and any future local-checks surface, can share it.
struct RunRecordStore: Equatable {
    private(set) var byWorktree: [String: [String?: [String: RunRecord]]] = [:]

    func record(worktreeID: String, projectId: String?, scriptKey: String) -> RunRecord? {
        byWorktree[worktreeID]?[projectId]?[scriptKey]
    }

    func records(worktreeID: String, projectId: String?) -> [RunRecord] {
        guard let scripts = byWorktree[worktreeID]?[projectId] else { return [] }
        return Array(scripts.values)
    }

    func allRecords(worktreeID: String) -> [RunRecord] {
        byWorktree[worktreeID]?.values.flatMap { $0.values } ?? []
    }

    func isCurrentActiveRun(runID: String, worktreeID: String, projectId: String?, scriptKey: String) -> Bool {
        guard let record = record(worktreeID: worktreeID, projectId: projectId, scriptKey: scriptKey) else { return false }
        return record.id == runID && record.status.isActive
    }

    var activeRecords: [RunRecord] {
        byWorktree.values.flatMap { $0.values.flatMap(\.values) }.filter(\.status.isActive)
    }

    /// Starts a run, returning the record it displaced so a launch that fails
    /// before the command exists can put the previous outcome back.
    @discardableResult
    mutating func begin(_ record: RunRecord) -> RunRecord? {
        var owners = byWorktree[record.worktreeID] ?? [:]
        var scripts = owners[record.projectId] ?? [:]
        let previous = scripts.updateValue(record, forKey: record.scriptKey)
        owners[record.projectId] = scripts
        byWorktree[record.worktreeID] = owners
        return previous
    }

    /// Undoes a `begin` whose launch never produced a command. A no-op once
    /// something else has taken the slot, so a stale rollback can't resurrect
    /// an old record over a newer run.
    mutating func rollback(runID: String, to previous: RunRecord?) {
        guard let location = locate(runID: runID) else { return }
        var owners = byWorktree[location.worktreeID] ?? [:]
        var scripts = owners[location.projectId] ?? [:]
        scripts[location.scriptKey] = previous
        owners[location.projectId] = scripts.isEmpty ? nil : scripts
        byWorktree[location.worktreeID] = owners.isEmpty ? nil : owners
    }

    mutating func markRunning(runID: String, sessionID: String) {
        _ = mutateActive(runID: runID) {
            $0.status = .running
            $0.sessionID = sessionID
        }
    }

    @discardableResult
    mutating func finish(runID: String, outcome: RunOutcome, at date: Date, failureID: String? = nil) -> RunRecord? {
        return mutateActive(runID: runID) {
            $0.status = .finished(outcome)
            $0.finishedAt = date
            $0.failureID = failureID
        }
    }

    /// User-initiated stop. Only an in-flight run can be stopped: a command
    /// that already reported an exit status keeps that outcome even when its
    /// shell is closed afterwards.
    @discardableResult
    mutating func markStopped(worktreeID: String, projectId: String?, scriptKey: String, at date: Date) -> RunRecord? {
        guard let record = record(worktreeID: worktreeID, projectId: projectId, scriptKey: scriptKey), record.status.isActive else { return nil }
        return mutateActive(runID: record.id) {
            $0.status = .finished(.stopped)
            $0.finishedAt = date
        }
    }

    /// Observation ended without an exit status (terminal killed, SSH dropped,
    /// monitor cancelled). Never resolves to success.
    @discardableResult
    mutating func markLostObservation(runID: String, at date: Date) -> RunRecord? {
        return mutateActive(runID: runID) {
            $0.status = .finished(.unknown)
            $0.finishedAt = date
        }
    }

    @discardableResult
    mutating func markLostObservation(worktreeID: String, projectId: String?, scriptKey: String, at date: Date) -> RunRecord? {
        guard let record = record(worktreeID: worktreeID, projectId: projectId, scriptKey: scriptKey) else { return nil }
        return markLostObservation(runID: record.id, at: date)
    }

    mutating func setPortConflict(_ conflict: RunPortConflict?, runID: String) {
        _ = mutateActive(runID: runID) { $0.portConflict = conflict }
    }

    mutating func purge(worktreeID: String) {
        byWorktree[worktreeID] = nil
    }

    mutating func purgeFinished(worktreeID: String) {
        filterRecords(worktreeID: worktreeID) { $0.status.isActive }
    }

    mutating func purgeFinished(worktreeID: String, finishedOnOrBefore cutoff: Date) {
        filterRecords(worktreeID: worktreeID) {
            $0.status.isActive || ($0.finishedAt ?? .distantPast) > cutoff
        }
    }

    mutating func purgeFinished(worktreeID: String, projectId: String, finishedOnOrBefore cutoff: Date) {
        filterRecords(worktreeID: worktreeID, projectId: projectId) {
            $0.status.isActive || ($0.finishedAt ?? .distantPast) > cutoff
        }
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

    private mutating func filterRecords(
        worktreeID: String,
        projectId filterProjectId: String? = nil,
        keeping: (RunRecord) -> Bool
    ) {
        guard var owners = byWorktree[worktreeID] else { return }
        for projectId in Array(owners.keys) {
            guard filterProjectId == nil || projectId == filterProjectId else { continue }
            guard let scripts = owners[projectId] else { continue }
            let retained = scripts.filter { keeping($0.value) }
            owners[projectId] = retained.isEmpty ? nil : retained
        }
        byWorktree[worktreeID] = owners.isEmpty ? nil : owners
    }

    private func locate(runID: String) -> (worktreeID: String, projectId: String?, scriptKey: String)? {
        for (worktreeID, owners) in byWorktree {
            for (projectId, scripts) in owners {
                for (scriptKey, record) in scripts where record.id == runID {
                    return (worktreeID, projectId, scriptKey)
                }
            }
        }
        return nil
    }

    private mutating func mutateActive(runID: String, _ body: (inout RunRecord) -> Void) -> RunRecord? {
        guard let location = locate(runID: runID),
              var record = byWorktree[location.worktreeID]?[location.projectId]?[location.scriptKey],
              record.status.isActive
        else { return nil }
        body(&record)
        byWorktree[location.worktreeID]?[location.projectId]?[location.scriptKey] = record
        return record
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
