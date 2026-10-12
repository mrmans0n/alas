import Foundation
import Observation
import os

private let runHistoryLogger = Logger(subsystem: "io.nlopez.alas", category: "RunScripts")

/// Where a finished run's output is read from when it is archived.
public enum RunHistoryCapture: Sendable {
    case completion(RunScriptCompletion)
    case location(RunScriptCaptureLocation)
    case snapshot(RunScriptTranscriptSnapshot, cleanup: RunScriptCaptureLocation)
    case unavailable

    /// Reads the local transcript before its monitor is cancelled, falling
    /// back to the location when nothing is on disk yet.
    public static func beforeCancelling(_ location: RunScriptCaptureLocation) -> RunHistoryCapture {
        if let snapshot = RunScriptCompletionMonitor.localSnapshot(for: location) {
            return .snapshot(snapshot, cleanup: location)
        }
        return .location(location)
    }

    public static func failed(_ error: Error, location: RunScriptCaptureLocation) -> RunHistoryCapture {
        if case let RunScriptCompletionMonitor.MonitorError.malformedStatus(snapshot) = error {
            return .snapshot(snapshot, cleanup: location)
        }
        return .location(location)
    }

    var cleanupLocation: RunScriptCaptureLocation? {
        switch self {
        case let .location(location), let .snapshot(_, cleanup: location): location
        case .completion, .unavailable: nil
        }
    }
}

/// Completed-run history: archives finished runs into the store and tracks
/// which reports each worktree can open.
@MainActor
@Observable
public final class RunHistory {
    /// Nil when Application Support cannot be opened; live runs keep working.
    @ObservationIgnored public let store: RunHistoryStore?
    /// Told when a run could not be saved or the history could not be cleared.
    @ObservationIgnored public var onFailure: @MainActor (_ message: String) -> Void = { _ in }

    /// Bumped on every change to any worktree's history.
    public private(set) var revision = 0
    private var revisionsByWorktreeID: [String: Int] = [:]
    public var durableReportIDsByWorktreeID: [String: Set<String>] = [:]
    @ObservationIgnored private var transientReports: [String: RunHistoryEntry] = [:]
    @ObservationIgnored private var persistenceTasks: [String: (worktreeID: String, task: Task<Void, Never>)] = [:]

    public init(store: RunHistoryStore?) {
        self.store = store
    }

    public func revision(worktreeID: String) -> Int {
        revisionsByWorktreeID[worktreeID, default: 0]
    }

    public func noteChanged(worktreeID: String) {
        revisionsByWorktreeID[worktreeID, default: 0] += 1
        revision += 1
    }

    /// Keeps a report that is not in the store, such as one for a run whose
    /// history could not be saved, openable until the history is cleared.
    public func addTransientReport(_ entry: RunHistoryEntry) {
        transientReports[Self.reportKey(worktreeID: entry.worktreeID, runID: entry.id)] = entry
        noteChanged(worktreeID: entry.worktreeID)
    }

    public func transientReport(worktreeID: String, runID: String) -> RunHistoryEntry? {
        transientReports[Self.reportKey(worktreeID: worktreeID, runID: runID)]
    }

    public func hasReport(worktreeID: String, runID: String) -> Bool {
        transientReport(worktreeID: worktreeID, runID: runID) != nil
            || durableReportIDsByWorktreeID[worktreeID, default: []].contains(runID)
    }

    public func hasPersistedReport(worktreeID: String, runID: String) async -> Bool {
        await flush(worktreeID: worktreeID)
        guard let store, (try? await store.entry(id: runID))?.worktreeID == worktreeID else { return false }
        durableReportIDsByWorktreeID[worktreeID, default: []].insert(runID)
        return true
    }

    public func reloadDurableReportIDs(worktreeID: String) async {
        durableReportIDsByWorktreeID[worktreeID] = (try? await store?.ids(worktreeID: worktreeID)) ?? []
    }

    /// Deletes the worktree's runs that finished by `cutoff` and forgets its
    /// transient reports. Throws, after reporting it, when the store fails.
    public func clear(worktreeID: String, finishedOnOrBefore cutoff: Date) async throws {
        if let store {
            await flush(worktreeID: worktreeID)
            do {
                try await RunHistoryPersistenceRetry.attempt {
                    try await store.clear(worktreeID: worktreeID, finishedOnOrBefore: cutoff)
                }
                durableReportIDsByWorktreeID[worktreeID] = try await store.ids(worktreeID: worktreeID)
            } catch {
                onFailure("Could not clear run history: \(error.localizedDescription)")
                throw error
            }
        }
        transientReports = transientReports.filter { $0.value.worktreeID != worktreeID }
        noteChanged(worktreeID: worktreeID)
    }

    /// Forgets the reports of a worktree that is going away. When
    /// `deletingStoredRuns`, its saved runs are deleted too, by the returned task.
    public func forget(worktreeID: String, deletingStoredRuns: Bool) -> Task<Void, Never>? {
        transientReports = transientReports.filter { $0.value.worktreeID != worktreeID }
        durableReportIDsByWorktreeID[worktreeID] = []
        guard deletingStoredRuns, let store else { return nil }
        return Task { @MainActor [weak self, store] in
            await self?.flush(worktreeID: worktreeID)
            do {
                try await RunHistoryPersistenceRetry.attempt { try await store.purge(worktreeID: worktreeID) }
                self?.noteChanged(worktreeID: worktreeID)
            } catch {
                self?.onFailure("Could not purge run history: \(error.localizedDescription)")
            }
        }
    }

    /// Saves a finished run with its output and releases the capture. A run
    /// that has not finished, or no store, only releases the capture.
    public func archive(_ record: RunRecord?, capture: RunHistoryCapture) {
        guard let record,
              let entry = Self.entry(for: record, output: .unavailable),
              let store
        else {
            Self.releaseInBackground(capture)
            return
        }
        track(runID: record.id, worktreeID: record.worktreeID, Task { @MainActor [weak self, store] in
            let output = await Self.output(for: capture)
            let entry = Self.entry(for: record, output: output) ?? entry
            do {
                let inserted = try await RunHistoryPersistenceRetry.attempt { try await store.append(entry) }
                if inserted {
                    self?.durableReportIDsByWorktreeID[record.worktreeID] = try await store.ids(worktreeID: record.worktreeID)
                    self?.noteChanged(worktreeID: record.worktreeID)
                }
            } catch {
                self?.onFailure("Could not save run history: \(error.localizedDescription)")
                runHistoryLogger.error(
                    "Could not persist run \(record.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            await Self.release(capture)
            self?.persistenceTasks.removeValue(forKey: record.id)
        })
    }

    /// Registers a save in flight so `flush` waits for it.
    public func track(runID: String, worktreeID: String, _ task: Task<Void, Never>) {
        persistenceTasks[runID] = (worktreeID, task)
    }

    /// Whether the run is being saved; its save releases the capture.
    public func isPersisting(runID: String) -> Bool {
        persistenceTasks[runID] != nil
    }

    /// Waits for the run's save, if one is in flight.
    public func flush(runID: String) async {
        await persistenceTasks[runID]?.task.value
    }

    /// Waits for the saves in flight, for one worktree or all of them.
    public func flush(worktreeID: String? = nil) async {
        let tasks = persistenceTasks.values.filter { worktreeID == nil || $0.worktreeID == worktreeID }
        for entry in tasks {
            await entry.task.value
        }
    }

    public static func releaseInBackground(_ capture: RunHistoryCapture) {
        guard let location = capture.cleanupLocation else { return }
        if case let .local(paths) = location { RunScriptCompletionMonitor.removeLocalCapture(paths) }
        Task { await RunScriptCompletionMonitor.cleanupRemoteCapture(for: location) }
    }

    private static func release(_ capture: RunHistoryCapture) async {
        guard let location = capture.cleanupLocation else { return }
        if case let .local(paths) = location { RunScriptCompletionMonitor.removeLocalCapture(paths) }
        await RunScriptCompletionMonitor.cleanupRemoteCapture(for: location)
    }

    private static func reportKey(worktreeID: String, runID: String) -> String {
        "\(worktreeID)\u{0}\(runID)"
    }

    private static func entry(for record: RunRecord, output: RunHistoryOutput) -> RunHistoryEntry? {
        guard let finishedAt = record.finishedAt,
              case let .finished(outcome) = record.status
        else { return nil }
        return RunHistoryEntry(
            id: record.id,
            scriptKey: record.scriptKey,
            scriptName: record.scriptName,
            worktreeID: record.worktreeID,
            branch: record.branch,
            target: record.target,
            endpoint: record.endpoint,
            outcome: outcome,
            startedAt: record.startedAt,
            finishedAt: finishedAt,
            portConflict: record.portConflict,
            output: output
        )
    }

    private static func output(for capture: RunHistoryCapture) async -> RunHistoryOutput {
        let snapshot: RunScriptTranscriptSnapshot
        switch capture {
        case let .completion(completion):
            snapshot = .init(transcript: completion.transcript, truncated: completion.truncated)
        case let .location(location):
            snapshot = await RunScriptCompletionMonitor.snapshot(for: location)
        case let .snapshot(captured, _):
            snapshot = captured
        case .unavailable:
            snapshot = .init(transcript: nil, truncated: false)
        }
        guard let transcript = snapshot.transcript else { return .unavailable }
        let tail = ANSIPlainTextSnapshot.tail(
            from: transcript,
            byteLimit: RunScriptCompletionMonitor.outputByteLimit,
            normalizesCRLF: true
        )
        return .available(text: tail.text, truncated: snapshot.truncated || tail.truncated)
    }
}
