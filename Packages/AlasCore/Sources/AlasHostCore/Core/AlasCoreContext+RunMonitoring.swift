import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

private let runMonitoringLogger = Logger(subsystem: "io.nlopez.alas", category: "RunScripts")

/// Waits for a run's completion file at a capture location.
public typealias RunCompletionWaiter = @Sendable (RunScriptCaptureLocation) async throws -> RunScriptCompletion

/// How a launched script settled. Delivered exactly once per run ID to
/// whoever asked to be told, which today is only the scheduler.
public enum RunScriptSettlement: Equatable, Sendable {
    case finished(RunOutcome)
    /// The command never started (terminal failed to open, shell rejected).
    case launchFailed(String)
}

/// A run whose completion file is being waited for.
public struct RunObservation {
    public let worktreeID: String
    /// The terminal session hosting the run; nil for a run in a plain process.
    public let sessionID: String?
    public let location: RunScriptCaptureLocation
    public let task: Task<Void, Never>

    public init(worktreeID: String, sessionID: String?, location: RunScriptCaptureLocation, task: Task<Void, Never>) {
        self.worktreeID = worktreeID
        self.sessionID = sessionID
        self.location = location
        self.task = task
    }
}

extension AlasCoreContext {
    // MARK: - Settlement

    /// Registers interest in how one run ends. The handler fires exactly once
    /// and is then dropped.
    @_spi(AppHost) public func awaitRunSettlement(
        runID: String,
        worktreeID: String,
        notify: @escaping (RunScriptSettlement) -> Void
    ) {
        runSettlementHandlers[runID] = (worktreeID: worktreeID, notify: notify)
    }

    /// Hands a waiting caller the run's final state. A no-op when nobody is
    /// waiting, so every teardown path can call it unconditionally.
    @_spi(AppHost) public func resolveRunSettlement(runID: String, _ settlement: RunScriptSettlement) {
        runSettlementHandlers.removeValue(forKey: runID)?.notify(settlement)
    }

    /// Settles every run a worktree owns. The last line of defense for
    /// teardown paths that discard runs wholesale instead of finishing them —
    /// without it, a scheduled run in a deleted worktree would wait forever
    /// and its schedule would never fire again.
    @_spi(AppHost) public func resolveRunSettlements(worktreeID: String, _ settlement: RunScriptSettlement) {
        for (runID, entry) in runSettlementHandlers where entry.worktreeID == worktreeID {
            resolveRunSettlement(runID: runID, settlement)
        }
    }

    /// Settles and archives a record that just finished. Every run that
    /// finishes a record funnels through here exactly once, which makes it the
    /// main place a waiting scheduler learns how the command ended. Paths that
    /// end observation *without* finishing a record resolve the settlement
    /// themselves.
    @_spi(AppHost) public func finalizeRun(_ record: RunRecord?, capture: RunHistoryCapture) {
        if let record, case .finished(let outcome) = record.status {
            resolveRunSettlement(runID: record.id, .finished(outcome))
        }
        runHistory.archive(record, capture: capture)
    }

    // MARK: - Observation

    /// Waits for the run's completion (`awaitCompletion`, or else its
    /// completion file) and
    /// finishes its record from it. `onFinished` is called with the finished
    /// record once it is archived; a failed run's record carries the run ID
    /// as its failure ID.
    @_spi(AppHost) public func observeRun(
        runID: String,
        sessionID: String?,
        location: RunScriptCaptureLocation,
        scriptKey: String,
        worktreeID: String,
        awaitCompletion: (@MainActor () async throws -> RunScriptCompletion)? = nil,
        onFinished: @escaping @MainActor (RunRecord, RunScriptCompletion) -> Void
    ) {
        runObservations[runID] = RunObservation(
            worktreeID: worktreeID,
            sessionID: sessionID,
            location: location,
            task: Task { @MainActor [weak self] in
                guard let self else { return }
                defer { runObservations.removeValue(forKey: runID) }
                do {
                    let completion: RunScriptCompletion
                    if let awaitCompletion {
                        completion = try await awaitCompletion()
                    } else {
                        completion = try await runCompletionWaiter(location)
                    }
                    guard runRecords.isCurrentActiveRun(runID: runID, worktreeID: worktreeID, scriptKey: scriptKey) else {
                        // Something replaced this run's slot while it was in
                        // flight, so its exit status no longer describes what
                        // the row holds. Nobody waiting can be told a result.
                        resolveRunSettlement(runID: runID, .finished(.unknown))
                        return
                    }
                    let failed = completion.exitCode != 0
                    let finalized = runRecords.finish(
                        runID: runID,
                        outcome: failed ? .failed(exitCode: completion.exitCode) : .succeeded,
                        // A process's completion is timed on this machine; a
                        // terminal run's file may come from another host's clock.
                        at: awaitCompletion == nil ? Date() : completion.completedAt,
                        failureID: failed ? runID : nil
                    )
                    finalizeRun(finalized, capture: .completion(completion))
                    if let finalized { onFinished(finalized, completion) }
                } catch is RunUndone {
                    // The run never started and was already put back.
                } catch is CancellationError where Task.isCancelled {
                    // `stopObservingRun` already recorded the lost
                    // observation; it owns that transition. A cancellation
                    // thrown by the completion source alone is a lost run
                    // like any other failure below.
                } catch {
                    // The waiter failed (dropped SSH, unreadable completion
                    // file). We never saw an exit status, so we can't claim one.
                    if sessionID == nil {
                        // A run in a plain process has a caller waiting for why.
                        processRunErrors[runID] = error
                    }
                    loseObservation(runID: runID, capture: .failed(error, location: location), release: .failed(error, location: location))
                    runMonitoringLogger.error(
                        "Run script completion monitor failed for run \(runID, privacy: .public) at \(String(describing: location), privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        )
    }

    /// Gives up on observing a run. Every caller reaches here because the run's
    /// shell went away before the command reported an exit status, so the
    /// record settles on `unknown` — never on success. Without an observation,
    /// `location` is the capture to release.
    @_spi(AppHost) public func stopObservingRun(runID: String, location: RunScriptCaptureLocation? = nil) {
        let entry = runObservations.removeValue(forKey: runID)
        guard let location = entry?.location ?? location else { return }
        let capture = RunHistoryCapture.beforeCancelling(location)
        entry?.task.cancel()
        loseObservation(runID: runID, capture: capture, release: .location(location))
    }

    /// Stops observing a run that is being stopped on purpose, returning the
    /// capture to archive it with.
    @_spi(AppHost) public func takeRunCapture(runID: String) -> RunHistoryCapture {
        guard let entry = runObservations.removeValue(forKey: runID) else { return .unavailable }
        let capture = RunHistoryCapture.beforeCancelling(entry.location)
        entry.task.cancel()
        return capture
    }

    /// Ends every observation, as quitting does: each observed run settles on
    /// `unknown`, and so does anyone still waiting.
    @_spi(AppHost) public func stopObservingAllRuns() {
        let now = Date()
        for (runID, entry) in runObservations {
            let capture = RunHistoryCapture.beforeCancelling(entry.location)
            entry.task.cancel()
            let finalized = runRecords.markLostObservation(runID: runID, at: now)
            finalizeRun(finalized, capture: capture)
            if finalized == nil {
                resolveRunSettlement(runID: runID, .finished(.unknown))
            }
        }
        runObservations.removeAll()
        for runID in runSettlementHandlers.keys {
            resolveRunSettlement(runID: runID, .finished(.unknown))
        }
    }

    /// Discards a worktree's runs because the worktree is going away: its
    /// observations stop, its records go, and anyone waiting on one of its runs
    /// is settled as `unknown`. Its stored history is deleted too when
    /// `deletingHistory`, by the returned task; otherwise observed runs are
    /// archived as lost first.
    @discardableResult
    @_spi(AppHost) public func discardRuns(worktreeID: String, deletingHistory: Bool) -> Task<Void, Never>? {
        for (runID, entry) in runObservations where entry.worktreeID == worktreeID {
            let capture = deletingHistory ? .location(entry.location) : RunHistoryCapture.beforeCancelling(entry.location)
            runObservations.removeValue(forKey: runID)?.task.cancel()
            if deletingHistory {
                RunHistory.releaseInBackground(capture)
            } else {
                finalizeRun(runRecords.markLostObservation(runID: runID, at: Date()), capture: capture)
            }
        }
        runRecords.purge(worktreeID: worktreeID)
        let historyPurge = runHistory.forget(worktreeID: worktreeID, deletingStoredRuns: deletingHistory)
        // Discarded runs never finish a record, so anything still waiting on
        // one is released here.
        resolveRunSettlements(worktreeID: worktreeID, .finished(.unknown))
        return historyPurge
    }

    /// The observed runs hosted by `sessionID`, optionally only local ones.
    @_spi(AppHost) public func observedRunIDs(sessionID: String, includeRemote: Bool = true) -> [String] {
        runObservations.compactMap { runID, entry in
            if !includeRemote, case .remote = entry.location { return nil }
            return entry.sessionID == sessionID ? runID : nil
        }
    }

    private func loseObservation(runID: String, capture: RunHistoryCapture, release: RunHistoryCapture) {
        if let finalized = runRecords.markLostObservation(runID: runID, at: Date()) {
            finalizeRun(finalized, capture: capture)
        } else {
            resolveRunSettlement(runID: runID, .finished(.unknown))
            if !runHistory.isPersisting(runID: runID) {
                RunHistory.releaseInBackground(release)
            }
        }
    }
}
