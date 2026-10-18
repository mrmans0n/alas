import Foundation

/// What `AlasCoreContext.startRun` did with a request.
public enum RunStart: Codable, Equatable, Sendable {
    /// A run slot was claimed under this run ID; the command is starting.
    case started(runID: String)
    /// A launch for the same (worktree, script) is already in flight.
    case alreadyStarting
    /// The worktree's project is gone; nothing to run against.
    case projectUnavailable
    /// The launch cannot proceed; `message` explains why to the user.
    case refused(title: String, message: String)
}

/// One run for a `RunLauncher` to start.
public struct RunLaunchRequest: Sendable {
    public let script: RunScript
    public let worktree: Worktree
    public let project: ProjectConfig
    public let runID: String
    /// Where the command publishes its transcript and completion.
    public let location: RunScriptCaptureLocation
    /// The captured command: it runs the script and publishes its completion.
    public let command: String
    /// The run's console stays out of sight unless asked for.
    public let isHidden: Bool
}

/// How a `RunLauncher` started a run, and so how its completion arrives.
public enum RunLaunch: Sendable {
    /// A terminal session hosts the run; its completion file is waited for.
    case hosted(sessionID: String)
    /// The launcher's own process: the task finishes with the run's
    /// completion, and cancelling it ends the process.
    case process(Task<RunScriptCompletion, Error>)
    /// Started, but with nothing to observe, so it settles as unknown.
    case unobservable
}

/// Starts runs for the core's run routine and hosts them: the app in a run
/// tab, a host without a UI in a plain process. Every requirement but
/// `launch` has a default fit for a launcher that hosts nothing itself.
@MainActor
public protocol RunLauncher: AnyObject {
    /// Why `script` cannot run in `worktree`, checked before anything is claimed.
    func refusal(for script: RunScript, in worktree: Worktree, project: ProjectConfig) -> String?
    /// Starts the command. Throwing means it never started.
    func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch
    /// Whether something the launcher owns hosts the script's latest run in
    /// the worktree, such as its run tab.
    func hostsRun(scriptKey: String, worktreeID: String) -> Bool
    /// Ends that host, for a run stopped on purpose or about to restart.
    func endRunHost(scriptKey: String, worktreeID: String)
    /// Ends the host session a launch opened, for a launch stopped while starting.
    func endRunHost(sessionID: String, worktreeID: String)
    /// Whether the terminal session hosting a run still exists.
    func hostSessionExists(_ sessionID: String) -> Bool
    /// Whether the terminal session hosting a run has no foreground process left.
    func hostSessionIsIdle(_ sessionID: String) -> Bool
    /// A run finished with an exit status and its record is archived.
    func runDidFinish(_ record: RunRecord, completion: RunScriptCompletion, script: RunScript, worktree: Worktree, sessionID: String?)
}

extension RunLauncher {
    public func refusal(for script: RunScript, in worktree: Worktree, project: ProjectConfig) -> String? { nil }
    public func hostsRun(scriptKey: String, worktreeID: String) -> Bool { false }
    public func endRunHost(scriptKey: String, worktreeID: String) {}
    public func endRunHost(sessionID: String, worktreeID: String) {}
    public func hostSessionExists(_ sessionID: String) -> Bool { false }
    public func hostSessionIsIdle(_ sessionID: String) -> Bool { false }
    public func runDidFinish(_ record: RunRecord, completion: RunScriptCompletion, script: RunScript, worktree: Worktree, sessionID: String?) {}
}

/// Runs scripts in a plain process on this machine, through the context's
/// `RunService`. Remote projects are refused: there is no terminal to reach them.
public final class HeadlessRunLauncher: RunLauncher {
    /// Stateless, so every headless environment can share one.
    public static let shared = HeadlessRunLauncher()

    public init() {}

    public func refusal(for script: RunScript, in worktree: Worktree, project: ProjectConfig) -> String? {
        project.host == nil ? nil : "Remote projects can only run scripts in a terminal."
    }

    public func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch {
        let runs = core.runs
        return .process(Task { @MainActor in
            try await runs.run(request.script, in: request.worktree, project: request.project, runID: request.runID)
        })
    }
}

/// How long a run outlives the terminal session hosting it before it is
/// given up on: the shell can exit before its command publishes completion.
public struct RunHostGrace: Sendable {
    /// For runs on this machine.
    public var local: Duration
    /// For every run, remote ones included.
    public var any: Duration

    public init(local: Duration = .seconds(2), any: Duration = .seconds(30)) {
        self.local = local
        self.any = any
    }
}

/// A launch claimed and still starting.
struct PendingRunLaunch {
    let id: UUID
    let runID: String
    let isHidden: Bool
    var task: Task<Void, Never>?
}

struct RunSlotKey: Hashable {
    let worktreeID: String
    let scriptKey: String
}

extension AlasCoreContext {
    // MARK: - Starting

    /// Claims the script's run slot in `worktree` and starts it through the
    /// environment's launcher. The record reads as starting right away, so a
    /// second request is refused until this one settles. `onSettled` is told
    /// exactly once how the run ended, including a launch that never started.
    @discardableResult
    public func startRun(
        _ script: RunScript,
        in worktree: Worktree,
        isHidden: Bool = false,
        onSettled: ((RunScriptSettlement) -> Void)? = nil
    ) -> RunStart {
        guard !isStopping else { return Self.stoppingRefusal }
        let key = RunSlotKey(worktreeID: worktree.id, scriptKey: script.key)
        guard pendingRunLaunches[key] == nil else { return .alreadyStarting }
        // Global scripts live in local Application Support and are read by
        // path: a remote shell cannot see them.
        if script.scope == .global, worktree.path.isRemoteAlasPath {
            return .refused(
                title: "Run Script Failed",
                message: "Global scripts run on your Mac and can't be launched on a remote worktree yet."
            )
        }
        // Remote repo scripts are found through the remote file layer, so their
        // path is not on this machine's disk.
        let requiresLocalScriptPath = !(script.scope == .repo && worktree.path.isRemoteAlasPath)
        guard !requiresLocalScriptPath || FileManager.default.fileExists(atPath: script.fileURL.path) else {
            return .refused(title: "Run Script Failed", message: "\(script.fileName) no longer exists on disk.")
        }
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else { return .projectUnavailable }
        let launcher = environment.runLauncher
        if let refusal = launcher.refusal(for: script, in: worktree, project: project) {
            return .refused(title: "Run Script Failed", message: refusal)
        }
        // A run still hosted would keep going next to the new one; restarting
        // stops it first. One whose host is gone is only waiting to be given up.
        if let current = runRecords.record(worktreeID: worktree.id, scriptKey: script.key), current.status.isActive,
           processRuns[current.id] != nil || launcher.hostsRun(scriptKey: script.key, worktreeID: worktree.id) {
            return .refused(title: "Run Script Failed", message: "\(script.displayName) is already running.")
        }
        // Refused before a record exists, so the row never flips to Starting.
        guard projects.admitsNewWork(in: worktree) else {
            return .refused(
                title: "Run Script Failed",
                message: "Wait for the current worktree operation to finish before running scripts."
            )
        }

        let runID = UUID().uuidString
        let target = runExecutionTarget(for: script, in: worktree)
        let displaced = runRecords.begin(RunRecord(
            id: runID,
            scriptKey: script.key,
            scriptName: script.displayName,
            worktreeID: worktree.id,
            branch: worktree.branch,
            target: target,
            endpoint: script.endpoint,
            status: .starting,
            startedAt: Date(),
            portConflict: runPortConflict(endpoint: script.endpoint, target: target, excludingRunID: runID)
        ))
        if let onSettled {
            awaitRunSettlement(runID: runID, worktreeID: worktree.id, notify: onSettled)
        }
        let launchID = UUID()
        pendingRunLaunches[key] = PendingRunLaunch(id: launchID, runID: runID, isHidden: isHidden)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if pendingRunLaunches[key]?.id == launchID {
                    pendingRunLaunches.removeValue(forKey: key)
                }
            }
            do {
                let location = try RunScriptCompletionMonitor.paths(runID: runID, host: project.host)
                let request = RunLaunchRequest(
                    script: script,
                    worktree: worktree,
                    project: project,
                    runID: runID,
                    location: location,
                    command: try RunScriptCommand.runScriptStartupScript(
                        script: script,
                        worktreeRoot: worktree.path,
                        branch: worktree.branch,
                        projectName: project.name,
                        repoRoot: project.path,
                        capturePaths: location.paths,
                        executionIdentity: RunScriptExecutionIdentity(runID: runID, worktreeID: worktree.id, projectID: project.id)
                    ),
                    isHidden: isHidden
                )
                let launch: RunLaunch
                do {
                    launch = try await launcher.launch(request, in: self)
                } catch {
                    RunHistory.releaseInBackground(.location(location))
                    throw error
                }
                if Task.isCancelled {
                    // Stopped while starting; the stop already settled it. Only
                    // what this launch opened is ended: a restart may already
                    // host the script's next run.
                    switch launch {
                    case .process(let process):
                        // Waited out, so whoever waits for this launch (a
                        // removal) knows the process has ended.
                        process.cancel()
                        _ = try? await process.value
                    case .hosted(let sessionID): launcher.endRunHost(sessionID: sessionID, worktreeID: worktree.id)
                    case .unobservable: break
                    }
                    return
                }
                observe(launch, request: request, displaced: displaced, launcher: launcher)
            } catch {
                if Task.isCancelled { return }
                // The command never started, so the previous outcome is still
                // the most recent thing observed: put it back.
                runRecords.rollback(runID: runID, to: displaced)
                resolveRunSettlement(runID: runID, .launchFailed(error.localizedDescription))
            }
        }
        pendingRunLaunches[key]?.task = task
        return .started(runID: runID)
    }

    static let stoppingRefusal = RunStart.refused(title: "Host stopping", message: "The host is stopping and starts no new runs.")

    /// Stops whatever the script's slot holds, then starts it again.
    @discardableResult
    public func restartRun(
        _ script: RunScript,
        in worktree: Worktree,
        isHidden: Bool = false,
        onSettled: ((RunScriptSettlement) -> Void)? = nil
    ) -> RunStart {
        guard !isStopping else { return Self.stoppingRefusal }
        let key = RunSlotKey(worktreeID: worktree.id, scriptKey: script.key)
        let runID = runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.id
        if pendingRunLaunches[key] != nil
            || runID.map({ processRuns[$0] != nil }) == true
            || environment.runLauncher.hostsRun(scriptKey: script.key, worktreeID: worktree.id) {
            stopRun(scriptKey: script.key, in: worktree)
        }
        return startRun(script, in: worktree, isHidden: isHidden, onSettled: onSettled)
    }

    /// Whether the script's launch in `worktree`, still starting, hides its
    /// console. Nil when nothing is starting.
    public func startingRunIsHidden(scriptKey: String, worktreeID: String) -> Bool? {
        pendingRunLaunches[RunSlotKey(worktreeID: worktreeID, scriptKey: scriptKey)]?.isHidden
    }

    /// Where a run of `script` in `worktree` executes.
    public func runExecutionTarget(for script: RunScript, in worktree: Worktree) -> RunExecutionTarget {
        RunExecutionTarget(
            host: projects.projects.first(where: { $0.id == worktree.projectId })?.host,
            workingDirectory: script.cwd.map { worktree.path.appendingPathComponent($0).path } ?? worktree.path.path
        )
    }

    // MARK: - Stopping

    /// Stops the script's run on purpose. The record is marked stopped before
    /// its host ends, so losing the host is never read as a lost run.
    public func stopRun(scriptKey: String, in worktree: Worktree) {
        let key = RunSlotKey(worktreeID: worktree.id, scriptKey: scriptKey)
        if let pending = pendingRunLaunches.removeValue(forKey: key) {
            settleStoppedLaunch(pending, worktreeID: worktree.id, scriptKey: scriptKey)
            return
        }
        let record = runRecords.record(worktreeID: worktree.id, scriptKey: scriptKey)
        let process = record.flatMap { processRuns.removeValue(forKey: $0.id) }
        let launcher = environment.runLauncher
        guard process != nil || launcher.hostsRun(scriptKey: scriptKey, worktreeID: worktree.id) else {
            // Nothing left to stop: whatever was running is gone, and it was
            // never seen to exit.
            finalizeRun(runRecords.markLostObservation(worktreeID: worktree.id, scriptKey: scriptKey, at: Date()), capture: .unavailable)
            return
        }
        let capture = record.map { takeRunCapture(runID: $0.id) } ?? .unavailable
        finalizeRun(runRecords.markStopped(worktreeID: worktree.id, scriptKey: scriptKey, at: Date()), capture: capture)
        process?.task.cancel()
        launcher.endRunHost(scriptKey: scriptKey, worktreeID: worktree.id)
    }

    /// Cancels launches still starting, in one worktree or everywhere.
    public func cancelStartingRuns(worktreeID: String? = nil) {
        for (key, pending) in pendingRunLaunches where worktreeID == nil || key.worktreeID == worktreeID {
            pendingRunLaunches.removeValue(forKey: key)
            settleStoppedLaunch(pending, worktreeID: key.worktreeID, scriptKey: key.scriptKey)
        }
    }

    /// Gives up on a worktree's runs without forgetting them, as closing all
    /// of its tabs does: launches stop, and running ones settle as unknown.
    public func abandonRuns(worktreeID: String) {
        cancelStartingRuns(worktreeID: worktreeID)
        cancelProcessRuns { $0 == worktreeID }
        for (runID, entry) in runObservations where entry.worktreeID == worktreeID {
            stopObservingRun(runID: runID)
        }
        let now = Date()
        for record in runRecords.records(worktreeID: worktreeID) where record.status.isActive {
            finalizeRun(runRecords.markLostObservation(runID: record.id, at: now), capture: .unavailable)
        }
        resolveRunSettlements(worktreeID: worktreeID, .finished(.unknown))
    }

    /// Ends and forgets a worktree's runs because the worktree is going away.
    /// Its stored history goes too when `deletingHistory`, by the returned task.
    @discardableResult
    public func forgetRuns(worktreeID: String, deletingHistory: Bool) -> Task<Void, Never>? {
        cancelStartingRuns(worktreeID: worktreeID)
        cancelProcessRuns { $0 == worktreeID }
        return discardRuns(worktreeID: worktreeID, deletingHistory: deletingHistory)
    }

    /// Ends every run, as quitting does: launches stop, and observed runs and
    /// anyone waiting on one settle as unknown.
    public func abandonAllRuns() {
        cancelStartingRuns()
        cancelProcessRuns { _ in true }
        stopObservingAllRuns()
    }

    // MARK: - Hosts

    /// Settles a worktree's active runs whose host session has gone away
    /// with nothing still observing them, so they stop reading as running.
    public func reconcileRuns(worktreeID: String) {
        let now = Date()
        let launcher = environment.runLauncher
        for record in runRecords.records(worktreeID: worktreeID) where record.status.isActive {
            guard let sessionID = record.sessionID, !launcher.hostSessionExists(sessionID) else { continue }
            // A completion file can outlive its shell; give up only once
            // nothing observes the run.
            guard observedRunIDs(sessionID: sessionID).isEmpty else { continue }
            finalizeRun(runRecords.markLostObservation(runID: record.id, at: now), capture: .unavailable)
        }
    }

    /// The process in a run's host session exited. Its runs are given up on
    /// if they have not reported completion within the grace period.
    public func runHostExited(sessionID: String) {
        stopObservingRuns(hostedBy: sessionID, after: runHostGrace.any)
    }

    /// A run's host session was closed. Local runs get the short grace period
    /// to publish completion, remote ones the long one.
    public func runHostClosed(sessionID: String) {
        stopObservingRuns(hostedBy: sessionID, after: runHostGrace.local, includeRemote: false)
        stopObservingRuns(hostedBy: sessionID, after: runHostGrace.any)
    }

    /// Stops observing the runs hosted by `sessionID`, now or after `delay`
    /// if they are still hosted there (and, with `onlyIfIdle`, still idle).
    public func stopObservingRuns(hostedBy sessionID: String, after delay: Duration? = nil, includeRemote: Bool = true, onlyIfIdle: Bool = false) {
        let runIDs = observedRunIDs(sessionID: sessionID, includeRemote: includeRemote)
        guard let delay else {
            for runID in runIDs { stopObservingRun(runID: runID) }
            return
        }
        for runID in runIDs {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, runObservations[runID]?.sessionID == sessionID else { return }
                if onlyIfIdle, !environment.runLauncher.hostSessionIsIdle(sessionID) { return }
                stopObservingRun(runID: runID)
            }
        }
    }

    // MARK: - Headless

    /// Runs `script` in `worktree` through the environment's launcher (a
    /// plain process headless) and waits for it, recording it and archiving
    /// its output. A run that never started leaves the previous record in
    /// place; one whose exit status was never observed finishes as `unknown`
    /// and rethrows why. A stopped run throws `CancellationError`, and so does
    /// cancelling the caller, which stops the run.
    @discardableResult
    public func runScript(_ script: RunScript, in worktree: Worktree) async throws -> RunOutcome {
        guard let project = projects.projects.first(where: { $0.id == worktree.projectId }) else {
            throw ProjectCreationError.projectNotFound
        }
        guard project.host == nil else { throw RunService.RunError.remoteProjectUnsupported }
        guard projects.admitsNewWork(in: worktree) else { throw WorktreeOperationInProgress() }
        guard runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive != true else {
            throw RunService.RunError.alreadyRunning
        }
        let started = StartedRun()
        let settlement: RunScriptSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch startRun(script, in: worktree, isHidden: true, onSettled: { continuation.resume(returning: $0) }) {
                case .started(let runID):
                    started.runID = runID
                case .alreadyStarting:
                    continuation.resume(returning: .launchFailed("\(script.displayName) is already starting."))
                case .projectUnavailable:
                    continuation.resume(returning: .launchFailed("The project is no longer available."))
                case let .refused(_, message):
                    continuation.resume(returning: .launchFailed(message))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let runID = started.runID else { return }
                self?.stopRun(runID: runID, scriptKey: script.key, in: worktree)
            }
        }
        switch settlement {
        case .launchFailed(let message):
            if let runID = started.runID, let error = processRunErrors.removeValue(forKey: runID) { throw error }
            throw RunLaunchFailure(message: message)
        case .finished(.stopped):
            throw CancellationError()
        case .finished(.unknown):
            if let runID = started.runID, let error = processRunErrors.removeValue(forKey: runID) { throw error }
            return .unknown
        case .finished(let outcome):
            return outcome
        }
    }

    /// Stops a worktree's runs in plain processes and waits until they have
    /// ended, before the worktree goes. Launches still starting are cancelled
    /// first, so none can start a process in the worktree afterwards.
    func stopProcessRuns(worktreeID: String) async {
        // Cancellation is cooperative: wait for the launches to unwind too.
        let launches = pendingRunLaunches.filter { $0.key.worktreeID == worktreeID }.compactMap(\.value.task)
        cancelStartingRuns(worktreeID: worktreeID)
        for launch in launches {
            await launch.value
        }
        let stopping = processRuns.filter { $0.value.worktreeID == worktreeID }
        for (_, run) in stopping {
            if let worktree = projects.worktrees(projectId: run.projectID).first(where: { $0.id == worktreeID }) {
                stopRun(scriptKey: run.scriptKey, in: worktree)
            } else {
                run.task.cancel()
            }
        }
        for (_, run) in stopping {
            _ = try? await run.task.value
        }
    }

    /// Waits until every launch now starting has started or failed.
    @_spi(Testing) public func waitForStartingRunsForTesting() async {
        for task in pendingRunLaunches.values.compactMap(\.task) {
            await task.value
        }
    }

    // MARK: - Private

    /// Ends the processes of runs being given up on: no longer observing a
    /// process does not stop it.
    private func cancelProcessRuns(where matches: (_ worktreeID: String) -> Bool) {
        for (runID, run) in processRuns where matches(run.worktreeID) {
            processRuns.removeValue(forKey: runID)
            run.task.cancel()
        }
    }

    /// Stops one run. When a restart has already taken the script's slot, only
    /// the run's own process is ended; the replacement is left alone.
    private func stopRun(runID: String, scriptKey: String, in worktree: Worktree) {
        let key = RunSlotKey(worktreeID: worktree.id, scriptKey: scriptKey)
        if pendingRunLaunches[key]?.runID == runID
            || runRecords.record(worktreeID: worktree.id, scriptKey: scriptKey)?.id == runID {
            stopRun(scriptKey: scriptKey, in: worktree)
        } else {
            processRuns.removeValue(forKey: runID)?.task.cancel()
        }
    }

    private func observe(_ launch: RunLaunch, request: RunLaunchRequest, displaced: RunRecord?, launcher: any RunLauncher) {
        let runID = request.runID
        let script = request.script
        let worktree = request.worktree
        let onFinished: @MainActor (RunRecord, RunScriptCompletion) -> Void = { record, completion in
            launcher.runDidFinish(record, completion: completion, script: script, worktree: worktree, sessionID: record.sessionID)
        }
        switch launch {
        case .hosted(let sessionID):
            observeRun(runID: runID, sessionID: sessionID, location: request.location, scriptKey: script.key, worktreeID: worktree.id, onFinished: onFinished)
            runRecords.markRunning(runID: runID, sessionID: sessionID)
            if launcher.hostSessionIsIdle(sessionID) {
                // The shell may already be gone: give up on the run unless it
                // reports completion first.
                stopObservingRuns(hostedBy: sessionID, after: runHostGrace.local, includeRemote: false, onlyIfIdle: true)
                stopObservingRuns(hostedBy: sessionID, after: runHostGrace.any, onlyIfIdle: true)
            }
        case .process(let process):
            processRuns[runID] = (worktree.id, worktree.projectId, script.key, process)
            observeRun(
                runID: runID,
                sessionID: nil,
                location: request.location,
                scriptKey: script.key,
                worktreeID: worktree.id,
                awaitCompletion: { [weak self] in
                    defer { self?.processRuns.removeValue(forKey: runID) }
                    do {
                        return try await process.value
                    } catch let neverStarted as RunService.NeverStarted {
                        // Like a launch that failed: put the previous outcome
                        // back, unless a stop has already settled the run.
                        guard let self, runRecords.isCurrentActiveRun(runID: runID, worktreeID: worktree.id, scriptKey: script.key) else {
                            throw RunUndone()
                        }
                        runRecords.rollback(runID: runID, to: displaced)
                        processRunErrors[runID] = neverStarted.underlying
                        resolveRunSettlement(runID: runID, .launchFailed(neverStarted.underlying.localizedDescription))
                        throw RunUndone()
                    }
                },
                onFinished: onFinished
            )
            runRecords.markRunning(runID: runID, sessionID: nil)
        case .unobservable:
            stopObservingRun(runID: runID, location: request.location)
        }
    }

    private func settleStoppedLaunch(_ pending: PendingRunLaunch, worktreeID: String, scriptKey: String) {
        pending.task?.cancel()
        let finalized = runRecords.markStopped(worktreeID: worktreeID, scriptKey: scriptKey, at: Date())
        finalizeRun(finalized, capture: .unavailable)
        // The cancelled launch never reaches its own error path, so anyone
        // waiting is told here that the command never ran to completion.
        if finalized == nil {
            resolveRunSettlement(runID: pending.runID, .finished(.stopped))
        }
    }

    /// Who else holds the run's endpoint port right now. Reported, never
    /// acted on: a process Alas does not own is never terminated.
    private func runPortConflict(endpoint: URL?, target: RunExecutionTarget, excludingRunID: String) -> RunPortConflict? {
        guard let port = endpoint?.runEndpointPort else { return nil }
        if let owner = runRecords.activeRunOwningPort(port, host: target.host, excludingRunID: excludingRunID) {
            return .ownedByRun(worktreeID: owner.worktreeID, branch: owner.branch, scriptName: owner.scriptName)
        }
        // A bind probe only means something for ports on this machine.
        guard !target.isRemote, RunPortProbe.isLocalPortInUse(port) else { return nil }
        return .externalProcess
    }
}

/// The run a `runScript` call started, read by its cancellation handler.
@MainActor
private final class StartedRun {
    var runID: String?
}

/// Thrown by a completion source whose run never started and was undone.
struct RunUndone: Error {}

/// A run whose command never started.
public struct RunLaunchFailure: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}
