import Foundation
import os

private let runScheduleLogger = Logger(subsystem: "io.nlopez.alas", category: "RunSchedules")

private enum ScheduledWorktreeCleanupCheck {
    case allowed(contentFingerprint: String)
    case refused(String)
}

private enum ScheduledWorktreeCleanupResult {
    case removed
    case retained(String)
    case failed(reason: String, worktreeRemoved: Bool)
}

/// How a launched script settled. Delivered exactly once per run ID to
/// whoever asked to be told, which today is only the scheduler.
enum RunScriptSettlement: Equatable, Sendable {
    case finished(RunOutcome)
    /// The command never started (terminal failed to open, shell rejected).
    case launchFailed(String)
    case cancelled
}

typealias ScheduledAgentReportFinalizer = @MainActor (
    ScheduledAgentReportStore,
    String,
    ScheduledAgentTaskState,
    String
) async throws -> Void

/// Races a script settlement against cancellation without ever resuming its
/// checked continuation more than once.
private final class ScheduledScriptSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RunScriptSettlement, Never>?
    private var pending: RunScriptSettlement?

    func install(_ continuation: CheckedContinuation<RunScriptSettlement, Never>) {
        lock.lock()
        let pending = self.pending
        if pending == nil {
            self.continuation = continuation
        }
        lock.unlock()
        if let pending {
            continuation.resume(returning: pending)
        }
    }

    func resolve(_ settlement: RunScriptSettlement) {
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return
        }
        pending = settlement
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: settlement)
    }
}

private final class ScheduledScriptRunID: @unchecked Sendable {
    private let lock = NSLock()
    private var valueStorage: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return valueStorage
    }

    func set(_ value: String) {
        lock.lock()
        valueStorage = value
        lock.unlock()
    }
}

extension AppState {
    // MARK: - Wiring

    func installRunScheduleRunner() {
        runScheduler.runner = { [weak self] schedule, invocation, firingID in
            guard let self else {
                return RunScheduleRunReport(outcome: .launchFailed("Alas is shutting down."))
            }
            return await self.runSchedule(schedule, invocation: invocation, firingID: firingID)
        }
    }

    /// Called once the worktree topology is loaded, because schedules
    /// resolve their targets against it.
    func startRunScheduler() {
        runScheduler.start()
    }

    // MARK: - Execution

    /// Runs a schedule once. Every step reuses the manual path: worktree
    /// creation goes through `createWorktreeAndWait`, the script through the
    /// same launch used by the Run tab, and the agent through the worktree
    /// launch surface. The returned outcome is what the schedule row shows.
    func runSchedule(
        _ schedule: RunSchedule,
        invocation: RunScheduleInvocation = .scheduled,
        firingID: String = UUID().uuidString
    ) async -> RunScheduleRunReport {
        await scheduledAgentReportsRecoveryTask?.value
        let targets: [(project: ProjectConfig, worktree: Worktree)]
        switch resolveScheduleTargets(schedule.target, invocation: invocation) {
        case .targets(let resolved):
            targets = resolved
        case .unavailable(let reason):
            return RunScheduleRunReport(outcome: .skipped(reason: reason))
        }
        // Start every target before waiting on any of them. Run scripts are
        // allowed to be long-running servers that never exit, so awaiting one
        // target's settlement before launching the next would let the first
        // project starve all the others indefinitely. Each child suspends on
        // its own run's settlement, which lets the next one start.
        let runs = targets.map { target in
            Task { @MainActor in
                await self.runSchedule(
                    schedule,
                    project: target.project,
                    worktree: target.worktree,
                    firingID: firingID,
                    targetRunID: UUID().uuidString
                )
            }
        }
        // Cancellation is forwarded by hand because these children are
        // unstructured and so do not inherit it. `RunScheduler` cancels the
        // task it dispatched when a schedule is removed, and without this
        // the targets would carry on regardless — including a prompt still
        // waiting to be typed into, and submitted to, an agent belonging to
        // a schedule that no longer exists.
        let reports = await withTaskCancellationHandler {
            var collected: [RunScheduleRunReport] = []
            for run in runs {
                collected.append(await run.value)
            }
            return collected
        } onCancel: {
            for run in runs { run.cancel() }
        }
        var outcomes: [RunScheduleOutcome] = []
        var references: [RunScheduleFiring.RunReference] = []
        var reportIDs: [String] = []
        for report in reports {
            outcomes.append(report.outcome)
            references.append(contentsOf: report.runs)
            reportIDs.append(contentsOf: report.reportIDs)
        }
        // Every target's run is linked, not just the one whose outcome won:
        // a fan-out that failed in one project should still let the user open
        // the reports of the projects that did run.
        return RunScheduleRunReport(
            outcome: .combined(outcomes),
            runs: references,
            reportIDs: reportIDs
        )
    }

    /// Whether a firing's run can actually be opened.
    ///
    /// Two things have to hold. The report must still exist, and its worktree
    /// must be one the centre pane can resolve. Archiving a worktree keeps its
    /// run history on purpose (`cleanupWorktreeState(purgeRunHistory: false)`),
    /// so the report outlives the worktree in the sidebar — but
    /// `CenterSelectionState` only resolves through `visibleWorktrees`, so
    /// selecting an archived id would empty the centre pane and strand the tab.
    /// The entry is still named in that case; it is just not a link.
    func canOpenScheduleFiringRun(_ run: RunScheduleFiring.RunReference) -> Bool {
        hasRunReport(worktreeID: run.worktreeID, runID: run.runID)
            && visibleProjectForWorktree(run.worktreeID) != nil
    }

    /// The project owning `worktreeID`, and only while that worktree is one
    /// the centre pane can resolve. Archived worktrees are excluded on
    /// purpose: see `canOpenScheduleFiringRun`.
    ///
    /// Also the Schedules pane's signal that visibility changed, because
    /// archiving and unarchiving alters what priming should do without
    /// altering which worktrees a history references.
    func visibleProjectForWorktree(_ worktreeID: String) -> ProjectConfig? {
        projects.first { project in
            projectsManager.visibleWorktrees(projectId: project.id).contains { $0.id == worktreeID }
        }
    }

    /// Opens the report of a run a firing started, navigating to that run
    /// first.
    ///
    /// A composed schedule's run is never in the worktree whose card shows it,
    /// and an `.allProjects` fan-out can land in another project — which may
    /// sit in another Space. `openRunReport` activates a tab under the run's
    /// worktree but changes no navigation, and `RootView` resolves the centre
    /// pane through the active Space's projects, so both the selection and the
    /// Space have to move or the pane is simply empty. `focusGlobalWorktree`
    /// is the existing path that does both.
    ///
    /// Firing in the background still never steals the selection; only
    /// following a link does, because that is an explicit request to go there.
    func openScheduleFiringRun(_ run: RunScheduleFiring.RunReference) {
        guard let project = visibleProjectForWorktree(run.worktreeID) else { return }
        focusGlobalWorktree(id: run.worktreeID, projectId: project.id)
        openRunReport(worktreeID: run.worktreeID, runID: run.runID)
    }

    /// Loads the durable report ids for worktrees a schedule's history points
    /// at, so its links work without first visiting each worktree's Run tab.
    /// A schedule that composes its own worktree otherwise shows entries whose
    /// reports exist but cannot be opened until something else happens to load
    /// them.
    ///
    /// Empty counts as unloaded, not as loaded-and-known-empty. Archiving a
    /// worktree clears this cache to `[]` while deliberately keeping the rows
    /// in the database, so a nil-only check would treat an unarchived worktree
    /// as already primed and leave its links dead for the rest of the session.
    /// Every worktree reaching here has at least one firing run, so an empty
    /// entry is always worth one query.
    func primeScheduleRunReportIDs(_ worktreeIDs: [String]) async {
        for worktreeID in worktreeIDs
            where durableRunReportIDsByWorktreeID[worktreeID]?.isEmpty != false {
            await reloadDurableRunReportIDs(worktreeID: worktreeID)
        }
    }

    enum ScheduleTargetResolution {
        case targets([(project: ProjectConfig, worktree: Worktree)])
        /// Nothing to run against; `reason` is shown on the schedule row.
        case unavailable(String)
    }

    func resolveScheduleTargets(
        _ target: RunScheduleTarget,
        invocation: RunScheduleInvocation = .scheduled
    ) -> ScheduleTargetResolution {
        switch target {
        case .allProjects:
            let candidates = projects.compactMap { project -> (project: ProjectConfig, worktree: Worktree)? in
                guard let main = projectsManager.visibleMainWorktree(projectId: project.id) else { return nil }
                return (project, main)
            }
            guard !candidates.isEmpty else { return .unavailable("No project has a main worktree to run in.") }
            // A schedule that names no single project still has to respect
            // "Pause <project>": without this the pause control would look
            // like it worked while the fan-out kept running there anyway.
            guard invocation.honorsProjectPauses else { return .targets(candidates) }
            let resolved = candidates.filter { !runScheduler.isProjectPaused($0.project.id) }
            guard !resolved.isEmpty else {
                return .unavailable("Every project with a main worktree is paused.")
            }
            return .targets(resolved)
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }) else {
                return .unavailable("The project no longer exists.")
            }
            if invocation.honorsProjectPauses, runScheduler.isProjectPaused(id) {
                return .unavailable("\(project.name) is paused.")
            }
            guard let main = projectsManager.visibleMainWorktree(projectId: id) else {
                return .unavailable("\(project.name) has no main worktree.")
            }
            return .targets([(project, main)])
        case let .worktree(projectId, worktreeId):
            guard let project = projects.first(where: { $0.id == projectId }) else {
                return .unavailable("The project no longer exists.")
            }
            if invocation.honorsProjectPauses, runScheduler.isProjectPaused(projectId) {
                return .unavailable("\(project.name) is paused.")
            }
            guard let worktree = projectsManager.worktrees(projectId: projectId).first(where: { $0.id == worktreeId }) else {
                return .unavailable("The worktree no longer exists in \(project.name).")
            }
            return .targets([(project, worktree)])
        }
    }

    private func runSchedule(
        _ schedule: RunSchedule,
        project: ProjectConfig,
        worktree originWorktree: Worktree,
        firingID: String,
        targetRunID: String
    ) async -> RunScheduleRunReport {
        var reportStore: ScheduledAgentReportStore?
        var reportID: String?
        var worktree = originWorktree

        if let composition = schedule.composition,
           composition.afterExecution == .reportAndCleanupOnSuccess {
            do {
                let store = try scheduledAgentReportsStore()
                let report = ScheduledAgentReport(
                    id: targetRunID,
                    occurrenceID: firingID,
                    scheduleID: schedule.id,
                    scheduleName: schedule.name,
                    projectID: project.id,
                    projectName: project.name,
                    agentID: composition.agentId ?? "unconfigured",
                    modelID: composition.modelId,
                    request: composition.prompt ?? "",
                    startedAt: Date(),
                    cleanupRequested: true
                )
                try await store.create(report)
                reportStore = store
                reportID = report.id
            } catch {
                let message = "Could not create the scheduled-agent report: \(error.localizedDescription)"
                reportScheduleFailure(schedule, reason: message, project: project, worktree: originWorktree)
                return RunScheduleRunReport(outcome: .launchFailed(message))
            }
            if let reason = scheduledAgentEligibilityFailure(composition) {
                let finalizationError = await finishScheduledReport(
                    reportID!,
                    state: .needsAttention,
                    reason: reason,
                    store: reportStore!
                )
                let outcomeReason = finalizationError.map {
                    "\($0) The report was not committed; the worktree was retained."
                } ?? reason
                if finalizationError != nil {
                    reportScheduleFailure(
                        schedule,
                        reason: outcomeReason,
                        project: project,
                        worktree: originWorktree,
                        reportID: reportID,
                        evenIfCancelled: true
                    )
                }
                return RunScheduleRunReport(
                    outcome: .launchFailed(outcomeReason),
                    reportIDs: [reportID!]
                )
            }
        }

        if let composition = schedule.composition {
            switch await createScheduledWorktree(for: schedule, composition: composition, project: project) {
            case .success(let created):
                worktree = created
                if let reportID, let reportStore {
                    do {
                        let baseCommit = try await GitService().headSHA(at: created.path)
                        try await reportStore.associateWorktree(
                            reportID: reportID,
                            worktreeID: created.id,
                            branch: created.branch,
                            baseCommit: baseCommit
                        )
                    } catch {
                        let reason = "Could not record the scheduled worktree identity: \(error.localizedDescription)"
                        let finalizationError = await finishScheduledReport(
                            reportID,
                            state: .failed,
                            reason: reason,
                            store: reportStore
                        )
                        let outcomeReason = finalizationError.map {
                            "\(reason) \($0) The report was not committed; the worktree was retained."
                        } ?? reason
                        reportScheduleFailure(
                            schedule,
                            reason: outcomeReason,
                            project: project,
                            worktree: created,
                            reportID: reportID,
                            evenIfCancelled: finalizationError != nil
                        )
                        return RunScheduleRunReport(
                            outcome: .launchFailed(outcomeReason),
                            reportIDs: [reportID]
                        )
                    }
                }
            case .failure(let failure):
                if Task.isCancelled {
                    var finalizationError: String?
                    if let reportID, let reportStore {
                        finalizationError = await finishScheduledReport(
                            reportID,
                            state: .interrupted,
                            reason: "The schedule was removed while its worktree was being created.",
                            store: reportStore
                        )
                    }
                    if let reportID, let finalizationError {
                        let reason = "\(finalizationError) The report was not committed; the worktree was retained."
                        reportScheduleFailure(
                            schedule,
                            reason: reason,
                            project: project,
                            worktree: originWorktree,
                            reportID: reportID,
                            evenIfCancelled: true
                        )
                        return RunScheduleRunReport(
                            outcome: .launchFailed(reason),
                            reportIDs: [reportID]
                        )
                    }
                    return RunScheduleRunReport(
                        outcome: .skipped(reason: "The schedule was removed while its worktree was being created."),
                        reportIDs: reportID.map { [$0] } ?? []
                    )
                }
                var finalizationError: String?
                if let reportID, let reportStore {
                    finalizationError = await finishScheduledReport(
                        reportID,
                        state: .failed,
                        reason: failure.message,
                        store: reportStore
                    )
                }
                let outcomeReason = finalizationError.map {
                    "\(failure.message) \($0) The report was not committed; the worktree was retained."
                } ?? failure.message
                reportScheduleFailure(
                    schedule,
                    reason: outcomeReason,
                    project: project,
                    worktree: originWorktree,
                    reportID: reportID,
                    evenIfCancelled: finalizationError != nil
                )
                return RunScheduleRunReport(
                    outcome: .launchFailed(outcomeReason),
                    reportIDs: reportID.map { [$0] } ?? []
                )
            }
        }

        var references: [RunScheduleFiring.RunReference] = []
        if let scriptKey = schedule.scriptKey {
            let script = await runScheduledScript(key: scriptKey, in: worktree, project: project)
            references = script.runs
            if let run = script.runs.first, let reportID, let reportStore {
                do {
                    try await reportStore.associateScriptRun(reportID: reportID, scriptRun: run)
                } catch {
                    let reason = "Could not record the scheduled script run: \(error.localizedDescription)"
                    let finalizationError = await finishScheduledReport(
                        reportID,
                        state: .failed,
                        reason: reason,
                        store: reportStore
                    )
                    let outcomeReason = finalizationError.map {
                        "\(reason) \($0) The report was not committed; the worktree was retained."
                    } ?? reason
                    reportScheduleFailure(
                        schedule,
                        reason: outcomeReason,
                        project: project,
                        worktree: worktree,
                        reportID: reportID,
                        evenIfCancelled: finalizationError != nil
                    )
                    return RunScheduleRunReport(
                        outcome: .launchFailed(outcomeReason),
                        runs: references,
                        reportIDs: [reportID]
                    )
                }
            }
            guard case .succeeded = script.outcome else {
                let reason = runScheduleOutcomeDescription(script.outcome)
                if let reportID, let reportStore {
                    if let finalizationError = await finishScheduledReport(
                        reportID,
                        state: Task.isCancelled ? .interrupted : (isSkipped(script.outcome) ? .needsAttention : .failed),
                        reason: reason,
                        store: reportStore
                    ) {
                        let outcomeReason = "\(finalizationError) The report was not committed; the worktree was retained."
                        reportScheduleFailure(
                            schedule,
                            reason: outcomeReason,
                            project: project,
                            worktree: worktree,
                            reportID: reportID,
                            evenIfCancelled: true
                        )
                        return RunScheduleRunReport(
                            outcome: .launchFailed(outcomeReason),
                            runs: references,
                            reportIDs: [reportID]
                        )
                    }
                }
                switch script.outcome {
                case .skipped:
                    break
                case .launchFailed(let message):
                    reportScheduleFailure(
                        schedule,
                        reason: message,
                        project: project,
                        worktree: worktree,
                        reportID: reportID
                    )
                default:
                    if schedule.composition != nil {
                        inAppNotifications.post(
                            "\(schedule.name): script did not succeed, agent not launched.\(reportID.map { " Report: \($0)." } ?? "")",
                            severity: .error,
                            worktreeID: worktree.id,
                            actionTitle: reportID == nil ? nil : "Open report",
                            action: scheduledAgentReportOpenAction(reportID)
                        )
                    }
                }
                return RunScheduleRunReport(
                    outcome: script.outcome,
                    runs: references,
                    reportIDs: reportID.map { [$0] } ?? []
                )
            }
        }

        guard let composition = schedule.composition else {
            return RunScheduleRunReport(outcome: .succeeded, runs: references)
        }
        if let reportID, let reportStore,
           let reason = scheduledAgentMCPUnavailableReason(project: project, worktree: worktree) {
            let finalizationError = await finishScheduledReport(
                reportID,
                state: .needsAttention,
                reason: reason,
                store: reportStore
            )
            let outcomeReason = finalizationError.map {
                "\($0) The report was not committed; the worktree was retained."
            } ?? reason
            if finalizationError != nil {
                reportScheduleFailure(
                    schedule,
                    reason: outcomeReason,
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: true
                )
            } else {
                inAppNotifications.post(
                    "\(schedule.name): \(outcomeReason) The worktree was retained. Report: \(reportID).",
                    severity: .error,
                    worktreeID: worktree.id,
                    actionTitle: "Open report",
                    action: scheduledAgentReportOpenAction(reportID)
                )
            }
            return RunScheduleRunReport(
                outcome: .launchFailed(outcomeReason),
                runs: references,
                reportIDs: [reportID]
            )
        }
        let agent = await launchScheduledAgent(
            for: schedule,
            composition: composition,
            worktree: worktree,
            project: project,
            reportID: reportID,
            occurrenceID: firingID
        )
        return RunScheduleRunReport(
            outcome: agent,
            runs: references,
            reportIDs: reportID.map { [$0] } ?? []
        )
    }

    private func scheduledAgentReportsStore() throws -> ScheduledAgentReportStore {
        if let scheduledAgentReportStore { return scheduledAgentReportStore }
        let store = try ScheduledAgentReportStore(path: scheduledAgentReportDatabasePath)
        scheduledAgentReportStore = store
        return store
    }

    func scheduledAgentReportPage(
        projectID: String,
        offset: Int,
        limit: Int = 40
    ) async throws -> [ScheduledAgentReport] {
        await scheduledAgentReportsRecoveryTask?.value
        let store = try scheduledAgentReportsStore()
        _ = try await store.reconcileAfterRestartIfNeeded()
        return try await store.page(
            projectID: projectID,
            offset: max(0, offset),
            limit: min(max(1, limit), 100)
        )
    }

    func scheduledAgentReportPrefix(
        projectID: String,
        limit: Int
    ) async throws -> [ScheduledAgentReport] {
        await scheduledAgentReportsRecoveryTask?.value
        let store = try scheduledAgentReportsStore()
        _ = try await store.reconcileAfterRestartIfNeeded()
        return try await store.page(
            projectID: projectID,
            offset: 0,
            limit: max(1, limit)
        )
    }

    func scheduledAgentReport(id: String) async throws -> ScheduledAgentReport? {
        await scheduledAgentReportsRecoveryTask?.value
        let store = try scheduledAgentReportsStore()
        _ = try await store.reconcileAfterRestartIfNeeded()
        return try await store.report(id: id)
    }
    func scheduledAgentReport(id: String, projectID: String) async throws -> ScheduledAgentReport? {
        guard let report = try await scheduledAgentReport(id: id),
              report.projectID == projectID
        else {
            return nil
        }
        return report
    }

    func deleteScheduledAgentReport(id: String, projectID: String) async throws -> Bool {
        await scheduledAgentReportsRecoveryTask?.value
        let store = try scheduledAgentReportsStore()
        _ = try await store.reconcileAfterRestartIfNeeded()
        guard let report = try await store.report(id: id),
              report.projectID == projectID
        else {
            return false
        }
        let deleted = try await store.delete(id: id)
        if deleted {
            scheduledAgentReportDeletionGeneration += 1
        }
        return deleted
    }

    func worktreeForScheduledAgentReport(_ report: ScheduledAgentReport) -> Worktree? {
        guard let worktreeID = report.worktreeID,
              let project = visibleProjectForWorktree(worktreeID)
        else {
            return nil
        }
        return projectsManager.visibleWorktrees(projectId: project.id).first { $0.id == worktreeID }
    }

    func scheduledAgentReportSessionIsAvailable(_ report: ScheduledAgentReport) async -> Bool {
        guard let sessionID = report.sessionID,
              let worktree = worktreeForScheduledAgentReport(report)
        else {
            return false
        }
        let persistence = ACPSessionPersistence(
            path: Paths.acpSessionsDB(forWorktreeId: worktree.id).path
        )
        guard let row = try? await persistence.loadSession(id: sessionID) else { return false }
        return !row.archived
    }

    func openScheduledAgentReportWorktree(_ report: ScheduledAgentReport) {
        guard let worktree = worktreeForScheduledAgentReport(report) else { return }
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
    }

    func openScheduledAgentReportSession(_ report: ScheduledAgentReport) async {
        guard let sessionID = report.sessionID,
              let worktree = worktreeForScheduledAgentReport(report)
        else {
            return
        }
        let persistence = ACPSessionPersistence(
            path: Paths.acpSessionsDB(forWorktreeId: worktree.id).path
        )
        guard let row = try? await persistence.loadSession(id: sessionID), !row.archived else { return }
        focusGlobalWorktree(id: worktree.id, projectId: worktree.projectId)
        await openExistingACPSession(sessionId: sessionID, worktree: worktree)
    }

    func requestOpenScheduledAgentReport(id: String) async {
        guard let report = try? await scheduledAgentReport(id: id),
              let worktree = projectsManager.visibleMainWorktree(projectId: report.projectID)
                ?? projectsManager.visibleWorktrees(projectId: report.projectID).first
        else {
            return
        }
        focusGlobalWorktree(id: worktree.id, projectId: report.projectID)
        scheduledAgentReportRoute = ScheduledAgentReportRoute(projectID: report.projectID, reportID: report.id)
        NotificationCenter.default.post(
            name: .alasSelectRightPaneTab,
            object: RightPaneTab.schedules.rawValue
        )
    }

    private func scheduledAgentEligibilityFailure(_ composition: RunScheduleComposition) -> String? {
        guard let agentID = composition.agentId,
              !agentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Scheduled report and cleanup require an explicitly selected ACP agent."
        }
        guard let spec = ACPLaunchCatalog.spec(for: agentID) else {
            return "Scheduled report and cleanup are available only for ACP agents; \(agentID) launches in a terminal."
        }
        if case .external = spec.mcpInjection {
            return "\(agentID) does not accept ACP MCP servers; scheduled report and cleanup require native MCP."
        }
        guard composition.sendsPromptAutomatically,
              let prompt = composition.prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Scheduled report and cleanup require a nonblank automatically submitted prompt."
        }
        return nil
    }

    private func scheduledAgentMCPUnavailableReason(project: ProjectConfig, worktree: Worktree) -> String? {
        guard project.host == nil else {
            return "The built-in Alas MCP server is unavailable for remote worktrees."
        }
        guard config.harness.exposeAlasMCP else {
            return "Built-in Alas MCP is disabled."
        }
        let binaryPath = (try? TerminalCLIInjection.installExecutables())?
            .appendingPathComponent(TerminalCLIInjection.executableName).path
        guard let binaryPath else {
            return "The Alas CLI executable is unavailable, so scheduled completion cannot be reported."
        }
        guard let socketPath = harness.socketServer.socketPath else {
            return "The Alas MCP socket is unavailable, so scheduled completion cannot be reported."
        }
        let configuredServers = RepoMCPResolver.merge(
            appServers: project.mcpServers,
            repoServers: repoConfig(worktreeRoot: worktree.path)?.mcpServers ?? [],
            disabledNames: Set(project.disabledRepoMCPServers),
            trust: project.repoMCPTrust
        ).active
        guard BuiltInAlasMCP.shouldInject(
            enabled: true,
            configuredServers: configuredServers,
            binaryPath: binaryPath,
            socketPath: socketPath
        ) else {
            return "A project MCP server named 'alas' overrides the built-in Alas server."
        }
        return nil
    }

    private func finishScheduledReport(
        _ reportID: String,
        state: ScheduledAgentTaskState,
        reason: String,
        store providedStore: ScheduledAgentReportStore? = nil
    ) async -> String? {
        let store: ScheduledAgentReportStore
        do {
            if let providedStore {
                store = providedStore
            } else {
                store = try scheduledAgentReportsStore()
            }
        } catch {
            let message = "Could not reopen the scheduled-agent report store: \(error.localizedDescription)"
            runScheduleLogger.error(
                "Could not reopen scheduled report \(reportID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return message
        }
        do {
            try await scheduledAgentReportFinalizer(store, reportID, state, reason)
            return nil
        } catch {
            let message = "Could not commit the scheduled-agent report finalization: \(error.localizedDescription)"
            runScheduleLogger.error(
                "Could not finalize scheduled report \(reportID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return message
        }
    }
    private func runScheduleOutcomeDescription(_ outcome: RunScheduleOutcome) -> String {
        switch outcome {
        case .succeeded:
            return "The scheduled script completed."
        case .failed(let exitCode):
            return "The scheduled script exited with code \(exitCode)."
        case .stopped:
            return "The scheduled script was stopped."
        case .unknown:
            return "The scheduled script ended without a known result."
        case .skipped(let reason), .launchFailed(let reason):
            return reason
        }
    }

    private func isSkipped(_ outcome: RunScheduleOutcome) -> Bool {
        if case .skipped = outcome { return true }
        return false
    }

    func recordScheduledAgentCompletion(
        origin: ACPOrchestrationSessionOrigin,
        completion: ScheduledAgentCompletion
    ) async -> AlasCLIResponse {
        let sessionID = origin.sessionId
        guard let registration = activeScheduledAgentRunsBySession[sessionID],
              registration.acceptsCompletion,
              registration.sessionID == sessionID,
              registration.worktreeID == origin.worktreeId,
              registration.projectID == origin.projectId
        else {
            return .error("No active scheduled ACP run accepts this completion.")
        }
        guard isWriter(for: sessionID),
              let manager = acpManager(forWorktreeId: registration.worktreeID),
              let session = manager.liveSession(for: sessionID),
              session.worktreeId == registration.worktreeID
        else {
            return .error("The authenticated ACP session does not own the active scheduled report.")
        }
        let builtInMCPIsRequested = session.mcpAttachmentSummary?.statuses.contains { status in
            guard status.id == BuiltInAlasMCP.statusId else { return false }
            if case .requested = status.disposition { return true }
            return false
        } == true
        guard builtInMCPIsRequested, session.builtInMCPRegistration == .registered else {
            return .error("The built-in Alas MCP server is not active for this scheduled ACP session.")
        }
        guard registration.reserveCompletion() else {
            return .error("A completion is already being recorded or this scheduled run is closed.")
        }
        do {
            let store = try scheduledAgentReportsStore()
            guard let report = try await store.report(id: registration.reportID),
                  report.taskState == .running,
                  report.cleanupRequested,
                  report.sessionID == sessionID,
                  report.worktreeID == registration.worktreeID,
                  report.projectID == origin.projectId,
                  report.agentID == session.agentId
            else {
                registration.retryAfterPersistenceFailure()
                return .error("The persisted report does not belong to this active scheduled ACP session.")
            }
            try await store.recordCompletion(
                reportID: registration.reportID,
                authenticatedSessionID: sessionID,
                completion: completion
            )
            guard activeScheduledAgentRunsBySession[sessionID] === registration,
                  registration.recordPersistedCompletion(completion)
            else {
                return .error("The scheduled run ended before this completion was accepted.")
            }
            return .text(["Completion recorded. The task turn must finish before cleanup can begin."])
        } catch {
            registration.retryAfterPersistenceFailure()
            if let storeError = error as? ScheduledAgentReportStoreError,
               case .completionAlreadyRecorded(_) = storeError {
                return .error("A completion has already been recorded for this scheduled run.")
            }
            return .error("Could not save the scheduled completion.")
        }
    }
    private func scheduledAgentReportOpenAction(_ reportID: String?) -> (() -> Void)? {
        guard let reportID else { return nil }
        return { [weak self] in
            Task { @MainActor [weak self] in
                await self?.requestOpenScheduledAgentReport(id: reportID)
            }
        }
    }

    /// Announces a failure that no other channel will report. A scheduled
    /// run's *script* outcome already reaches Notification Center through the
    /// run-script monitor; the steps around it — creating the worktree,
    /// starting the command, launching the agent — have nothing else, and the
    /// user is by definition not watching.
    private func reportScheduleFailure(
        _ schedule: RunSchedule,
        reason: String,
        project: ProjectConfig,
        worktree: Worktree,
        reportID: String? = nil,
        evenIfCancelled: Bool = false
    ) {
        guard evenIfCancelled || !Task.isCancelled else { return }
        let notificationReason = reportID.map { reason.contains($0) ? reason : "\(reason) Report: \($0)." } ?? reason
        inAppNotifications.post(
            "\(schedule.name): \(notificationReason)",
            severity: .error,
            worktreeID: worktree.id,
            actionTitle: reportID == nil ? nil : "Open report",
            action: scheduledAgentReportOpenAction(reportID)
        )
        harness.notifications.notifyScheduleFailed(
            scheduleName: schedule.name,
            reason: notificationReason,
            projectId: project.id,
            worktreeId: worktree.id,
            scheduleID: schedule.id
        )
    }

    private func createScheduledWorktree(
        for schedule: RunSchedule,
        composition: RunScheduleComposition,
        project: ProjectConfig
    ) async -> Result<Worktree, WorktreeCreationFailure> {
        let rendered = RunSchedulePlanner.renderBranch(
            template: composition.branchTemplate,
            name: schedule.name,
            now: Date()
        )
        switch GitNameValidator.validateBranchName(rendered) {
        case .valid:
            break
        case .invalid(let message):
            return .failure(.init(message: "Invalid branch name \"\(rendered)\": \(message)"))
        }
        // A template need not vary per occurrence — "nightly" is a reasonable
        // thing to type, and `{name}-{date}` repeats all day on an interval
        // schedule. Without a free suffix the first run would take the name
        // and every later one would collide with what it left behind: the
        // destination it still occupies, or the branch it kept after the
        // worktree went away.
        let repoPath = URL(fileURLWithPath: project.path)
        let git = GitService()
        // Local branches only: `WorktreeService.add` decides whether to reuse
        // a branch from `refs/heads/<branch>`, and a remote-tracking
        // `origin/nightly` with no local branch is still cut from the base.
        let existingBranches = Set((try? await git.localBranches(at: repoPath)) ?? [])
        let probe = scheduledDestinationExistence
        let host = project.host
        let free = await ScheduledWorktreeDestination.firstFree(
            rendered: rendered,
            pathTemplate: config.worktrees.pathTemplate,
            worktreeRoot: config.worktrees.rootPath,
            repoName: project.name,
            existingBranches: existingBranches,
            pathState: { await probe($0, host) }
        )
        let branch: String
        let destination: URL
        switch free {
        case let .free(freeBranch, freeDestination):
            branch = freeBranch
            destination = freeDestination
        case .exhausted:
            return .failure(.init(
                message: "Could not find a free branch and worktree path for \(rendered); clean up old scheduled worktrees."
            ))
        case .undeterminable(let path):
            return .failure(.init(
                message: "Could not check whether \(path.path) already exists on \(host ?? "this Mac")."
            ))
        }
        let availableBranches = (try? await git.branches(at: repoPath)) ?? []
        let base = NewWorktreeDialog.preferredBaseBranch(
            availableBranches: availableBranches,
            configuredDefault: config.worktrees.baseBranch
        )
        return await createWorktreeAndWait(
            projectId: project.id,
            base: base,
            branch: branch,
            destination: destination,
            runStartup: true
        )
    }

    private func runScheduledScript(
        key: String,
        in worktree: Worktree,
        project: ProjectConfig
    ) async -> RunScheduleRunReport {
        let discovery = await runScheduleScriptDiscovery(worktree.path, project.host)
        let scripts: [RunScript]
        switch discovery {
        case .scripts(let found):
            scripts = found
        case .failed(let message):
            return RunScheduleRunReport(
                outcome: .launchFailed("Could not list scripts in \(worktree.branch): \(message)")
            )
        }
        guard let script = scripts.first(where: { $0.key == key }) else {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "Script \(key) was not found in \(worktree.branch).")
            )
        }
        if runningScriptTab(for: script, in: worktree) != nil
            || runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive == true {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "\(script.displayName) is already running in \(worktree.branch).")
            )
        }
        var reference: RunScheduleFiring.RunReference?
        let settlementGate = ScheduledScriptSettlement()
        let runID = ScheduledScriptRunID()
        let settlement: RunScriptSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                settlementGate.install(continuation)
                guard !Task.isCancelled else {
                    settlementGate.resolve(.cancelled)
                    return
                }
                switch startScriptLaunch(script, in: worktree, presentsLaunchFailure: false) {
                case .started(let startedRunID):
                    runID.set(startedRunID)
                    reference = RunScheduleFiring.RunReference(
                        worktreeID: worktree.id,
                        branch: worktree.branch,
                        runID: startedRunID,
                        scriptName: script.displayName
                    )
                    awaitRunScriptSettlement(runID: startedRunID, worktreeID: worktree.id) {
                        settlementGate.resolve($0)
                    }
                    if Task.isCancelled {
                        resolveRunScriptSettlement(runID: startedRunID, .cancelled)
                    }
                case .alreadyStarting:
                    settlementGate.resolve(.launchFailed("\(script.displayName) is already starting in \(worktree.branch)."))
                case .projectUnavailable:
                    settlementGate.resolve(.launchFailed("The project is no longer available."))
                case let .refused(_, message):
                    settlementGate.resolve(.launchFailed(message))
                }
            }
        } onCancel: {
            settlementGate.resolve(.cancelled)
            Task { @MainActor [weak self] in
                guard let self, let runID = runID.value else { return }
                self.resolveRunScriptSettlement(runID: runID, .cancelled)
            }
        }
        switch settlement {
        case .finished(let outcome):
            // Only a settled run is archived, so only a settled run has a
            // report to link. A launch that never produced a command had its
            // record rolled back, and its reference would point at nothing.
            return RunScheduleRunReport(
                outcome: RunScheduleOutcome(outcome),
                runs: reference.map { [$0] } ?? []
            )
        case .launchFailed(let message):
            return RunScheduleRunReport(outcome: .launchFailed(message))
        case .cancelled:
            return RunScheduleRunReport(
                outcome: .skipped(reason: "The schedule was removed while its script was running."),
                runs: reference.map { [$0] } ?? []
            )
        }
    }

    /// Where a scheduled agent opens. An agent that speaks ACP gets a chat
    /// session, which takes the prompt and model as data instead of as
    /// keystrokes; any other agent gets its terminal. Decided at fire time so
    /// a "Project default" agent is judged by what it resolves to then.
    ///
    /// `text` is the prompt as written: a chat message keeps its line breaks.
    /// The terminal path still flattens it in `terminalText(for:)`.
    nonisolated static func scheduledLaunchSurface(
        agentId: String,
        composition: RunScheduleComposition,
        sessionID: ACPSession.ID = UUID().uuidString,
        promptID: UUID = UUID(),
        promptOverride: String? = nil
    ) -> WorktreeLaunchSurface {
        guard ACPLaunchCatalog.spec(for: agentId) != nil else {
            return .terminal(agentId: agentId)
        }
        return .acp(agentId: agentId, preparedPrompt: PreparedWorktreeACPPrompt(
            sessionID: sessionID,
            promptID: promptID,
            text: promptOverride ?? composition.prompt ?? "",
            sendsAutomatically: composition.sendsPromptAutomatically,
            modelID: composition.modelId
        ))
    }

    private func launchScheduledAgent(
        for schedule: RunSchedule,
        composition: RunScheduleComposition,
        worktree: Worktree,
        project: ProjectConfig,
        reportID: String?,
        occurrenceID: String
    ) async -> RunScheduleOutcome {
        let agentId = composition.agentId ?? defaultAgentID(projectId: project.id, worktreeRoot: worktree.path)
        guard let agentId else {
            let message = "No agent is configured to launch for \(project.name)."
            var finalizationError: String?
            if let reportID {
                finalizationError = await finishScheduledReport(
                    reportID,
                    state: .failed,
                    reason: message
                )
            }
            let outcomeReason = finalizationError.map {
                "\(message) \($0) The report was not committed; the worktree was retained."
            } ?? message
            reportScheduleFailure(
                schedule,
                reason: outcomeReason,
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            return .launchFailed(outcomeReason)
        }
        let sessionID = UUID().uuidString
        let promptID = UUID()
        let promptOverride: String? = reportID.map { _ in
            """
            \(composition.prompt ?? "")

            ---
            This is a scheduled task. After the work is complete, call the `schedule_complete` MCP tool exactly once with `succeeded`, `failed`, or `needs_attention`, a concise summary, completed checks, and any output links. Do not use a CLI command as a completion fallback. Reporting success does not authorize or trigger worktree deletion.
            """
        }
        let launchSurface = Self.scheduledLaunchSurface(
            agentId: agentId,
            composition: composition,
            sessionID: sessionID,
            promptID: promptID,
            promptOverride: promptOverride
        )
        if let reportID {
            guard case .acp(_, let prepared?) = launchSurface else {
                let reason = "Scheduled report and cleanup require a native ACP session."
                let finalizationError = await finishScheduledReport(
                    reportID,
                    state: .needsAttention,
                    reason: reason
                )
                let outcomeReason = finalizationError.map {
                    "\(reason) \($0) The report was not committed; the worktree was retained."
                } ?? reason
                reportScheduleFailure(
                    schedule,
                    reason: outcomeReason,
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: finalizationError != nil
                )
                return .launchFailed(outcomeReason)
            }
            do {
                let store = try scheduledAgentReportsStore()
                try await store.associateSession(reportID: reportID, sessionID: prepared.sessionID)
                activeScheduledAgentRunsBySession[prepared.sessionID] = ScheduledAgentRunRegistration(
                    reportID: reportID,
                    occurrenceID: occurrenceID,
                    scheduleID: schedule.id,
                    projectID: project.id,
                    worktreeID: worktree.id,
                    worktreeLineageID: worktree.lineageID,
                    sessionID: prepared.sessionID,
                    promptID: prepared.promptID
                )
            } catch {
                let reason = "Could not bind the scheduled report to its ACP session: \(error.localizedDescription)"
                let finalizationError = await finishScheduledReport(
                    reportID,
                    state: .failed,
                    reason: reason
                )
                let outcomeReason = finalizationError.map {
                    "\(reason) \($0) The report was not committed; the worktree was retained."
                } ?? reason
                reportScheduleFailure(
                    schedule,
                    reason: outcomeReason,
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: finalizationError != nil
                )
                return .launchFailed(outcomeReason)
            }
        }
        defer {
            if let registration = activeScheduledAgentRunsBySession[sessionID],
               registration.reportID == reportID {
                registration.invalidate()
                activeScheduledAgentRunsBySession[sessionID] = nil
            }
            scheduledPromptSettlementTasks.removeValue(forKey: sessionID)?.cancel()
        }
        guard !Task.isCancelled else {
            let reason = "The schedule was removed while its agent was launching."
            var finalizationError: String?
            if let reportID {
                finalizationError = await finishScheduledReport(
                    reportID,
                    state: .interrupted,
                    reason: reason
                )
            }
            if let reportID, let finalizationError {
                let message = "\(finalizationError) The report was not committed; the worktree was retained."
                reportScheduleFailure(
                    schedule,
                    reason: message,
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: true
                )
                return .launchFailed(message)
            }
            return .skipped(reason: reason)
        }
        let tab: Tab?
        do {
            tab = try await launchWorktreeSurface(launchSurface, worktree: worktree, project: project)
        } catch {
            if Task.isCancelled || error is CancellationError {
                let reason = "The schedule was removed while its agent was launching."
                var finalizationError: String?
                if let reportID {
                    finalizationError = await finishScheduledReport(
                        reportID,
                        state: .interrupted,
                        reason: reason
                    )
                }
                if let reportID, let finalizationError {
                    let message = "\(finalizationError) The report was not committed; the worktree was retained."
                    reportScheduleFailure(
                        schedule,
                        reason: message,
                        project: project,
                        worktree: worktree,
                        reportID: reportID,
                        evenIfCancelled: true
                    )
                    return .launchFailed(message)
                }
                return .skipped(reason: reason)
            }
            markWorktreeLaunchFailed(
                worktree: worktree,
                projectId: project.id,
                error: error,
                launchSurface: launchSurface
            )
            let reason = error.localizedDescription
            var finalizationError: String?
            if let reportID {
                finalizationError = await finishScheduledReport(
                    reportID,
                    state: .failed,
                    reason: reason
                )
            }
            let outcomeReason = finalizationError.map {
                "\(reason) \($0) The report was not committed; the worktree was retained."
            } ?? reason
            reportScheduleFailure(
                schedule,
                reason: outcomeReason,
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            runScheduleLogger.error(
                "Scheduled agent launch failed for \(schedule.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .launchFailed(outcomeReason)
        }
        let agentName = agentRegistry.agents.first { $0.id == agentId }?.displayName ?? agentId
        if case .acp(_, let prepared?) = launchSurface {
            return await scheduledChatSessionOutcome(
                prepared,
                schedule: schedule,
                worktree: worktree,
                project: project,
                agentName: agentName,
                reportID: reportID
            )
        }
        inAppNotifications.post(
            "\(schedule.name): launched \(agentName) in \(worktree.branch)",
            severity: .success,
            worktreeID: worktree.id
        )
        if let prompt = composition.prompt, case .terminal(let terminal)? = tab {
            await deliverScheduledPrompt(
                prompt,
                sendsAutomatically: composition.sendsPromptAutomatically,
                sessionID: terminal.root.firstLeaf().sessionId,
                schedule: schedule,
                worktree: worktree,
                host: project.host,
                agentID: agentId
            )
        }
        return .succeeded
    }

    /// Launch-only ACP schedules settle when the agent is ready. Report-enabled
    /// runs instead settle on their exact queued prompt, a durable completion,
    /// and an idle session with no queued work or outstanding user input.
    private func scheduledChatSessionOutcome(
        _ prepared: PreparedWorktreeACPPrompt,
        schedule: RunSchedule,
        worktree: Worktree,
        project: ProjectConfig,
        agentName: String,
        reportID: String?
    ) async -> RunScheduleOutcome {
        guard !Task.isCancelled else {
            let reason = "The schedule was removed while its agent was launching."
            var finalizationError: String?
            if let reportID {
                finalizationError = await finishScheduledReport(
                    reportID,
                    state: .interrupted,
                    reason: reason
                )
            }
            if let reportID, let finalizationError {
                let message = "\(finalizationError) The report was not committed; the worktree was retained."
                reportScheduleFailure(
                    schedule,
                    reason: message,
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: true
                )
                return .launchFailed(message)
            }
            return .skipped(reason: reason)
        }
        guard let manager = acpManager(forWorktreeId: worktree.id),
              let session = manager.liveSession(for: prepared.sessionID)
        else {
            let reason = "Could not open a chat session for \(agentName) in \(worktree.branch)."
            var finalizationError: String?
            if let reportID {
                finalizationError = await finishScheduledReport(
                    reportID,
                    state: .failed,
                    reason: reason
                )
            }
            let outcomeReason = finalizationError.map {
                "\(reason) \($0) The report was not committed; the worktree was retained."
            } ?? reason
            reportScheduleFailure(
                schedule,
                reason: "\(outcomeReason)\(reportID.map { " Report: \($0)." } ?? "")",
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            return .launchFailed(outcomeReason)
        }
        if let reason = session.lastError {
            let message = "\(agentName) could not start in \(worktree.branch): \(reason)"
            var finalizationError: String?
            if let reportID {
                finalizationError = await finishScheduledReport(
                    reportID,
                    state: .failed,
                    reason: message
                )
            }
            let outcomeReason = finalizationError.map {
                "\(message) \($0) The report was not committed; the worktree was retained."
            } ?? message
            reportScheduleFailure(
                schedule,
                reason: "\(outcomeReason)\(reportID.map { " Report: \($0)." } ?? "")",
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            return .launchFailed(outcomeReason)
        }
        if let modelID = prepared.modelID, session.currentModel != modelID {
            let modelName = acpModelCatalog.models(for: session.agentId).first { $0.id == modelID }?.name ?? modelID
            inAppNotifications.post(
                "\(schedule.name): \(agentName) did not accept the model \(modelName), so it is using its default.",
                severity: .error,
                worktreeID: worktree.id
            )
        }
        guard let reportID else {
            inAppNotifications.post(
                "\(schedule.name): launched \(agentName) in \(worktree.branch)",
                severity: .success,
                worktreeID: worktree.id
            )
            return .succeeded
        }
        guard let settlementTask = scheduledPromptSettlementTasks[prepared.sessionID] else {
            let reason = "The scheduled ACP prompt could not be observed; the worktree was retained."
            let finalizationError = await finishScheduledReport(
                reportID,
                state: .needsAttention,
                reason: reason
            )
            let outcomeReason = finalizationError.map {
                "\(reason) \($0) The report was not committed; the worktree was retained."
            } ?? reason
            reportScheduleFailure(
                schedule,
                reason: "\(outcomeReason) Report: \(reportID).",
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            return .launchFailed(outcomeReason)
        }
        let settlement = await withTaskCancellationHandler {
            await settlementTask.value
        } onCancel: {
            settlementTask.cancel()
        }
        let store: ScheduledAgentReportStore
        do {
            store = try scheduledAgentReportsStore()
        } catch {
            let reason = "Could not reopen the scheduled-agent report store: \(error.localizedDescription). The report was not committed; the worktree was retained."
            reportScheduleFailure(
                schedule,
                reason: "\(reason) Report: \(reportID).",
                project: project,
                worktree: worktree,
                reportID: reportID
            )
            return .launchFailed(reason)
        }
        switch settlement {
        case .cancelled:
            let reason = "The schedule was removed while the ACP task was running."
            if let finalizationError = await finishScheduledReport(
                reportID,
                state: .interrupted,
                reason: reason,
                store: store
            ) {
                let message = "\(finalizationError) The report was not committed; the worktree was retained."
                reportScheduleFailure(
                    schedule,
                    reason: message,
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: true
                )
                return .launchFailed(message)
            }
            return .skipped(reason: reason)
        case .timedOut:
            let reason = "The ACP task did not finish within four hours; its worktree was retained."
            let finalizationError = await finishScheduledReport(
                reportID,
                state: .needsAttention,
                reason: reason,
                store: store
            )
            let outcomeReason = finalizationError.map {
                "\($0) The report was not committed; the worktree was retained."
            } ?? reason
            reportScheduleFailure(
                schedule,
                reason: "\(outcomeReason) Report: \(reportID).",
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            return .launchFailed(outcomeReason)
        case .failed(let message):
            let finalizationError = await finishScheduledReport(
                reportID,
                state: .failed,
                reason: message,
                store: store
            )
            let outcomeReason = finalizationError.map {
                "\($0) The report was not committed; the worktree was retained."
            } ?? message
            reportScheduleFailure(
                schedule,
                reason: "\(outcomeReason) Worktree retained. Report: \(reportID).",
                project: project,
                worktree: worktree,
                reportID: reportID,
                evenIfCancelled: finalizationError != nil
            )
            return .launchFailed(outcomeReason)
        case .settled, .settledWithUnrelatedPrompt:
            guard let completion = activeScheduledAgentRunsBySession[prepared.sessionID]?.completion else {
                let reason = "The ACP task ended without calling schedule_complete; its worktree was retained."
                let finalizationError = await finishScheduledReport(
                    reportID,
                    state: .needsAttention,
                    reason: reason,
                    store: store
                )
                let outcomeReason = finalizationError.map {
                    "\($0) The report was not committed; the worktree was retained."
                } ?? reason
                reportScheduleFailure(
                    schedule,
                    reason: "\(outcomeReason) Report: \(reportID).",
                    project: project,
                    worktree: worktree,
                    reportID: reportID,
                    evenIfCancelled: finalizationError != nil
                )
                return .launchFailed(outcomeReason)
            }
            do {
                let report = try await store.finishRecordedCompletion(
                    reportID: reportID,
                    authenticatedSessionID: prepared.sessionID
                )
                guard report.taskState == .succeeded else {
                    let reason = "The ACP agent reported \(completion.outcome.rawValue); the worktree was retained."
                    reportScheduleFailure(
                        schedule,
                        reason: "\(reason) Report: \(reportID).",
                        project: project,
                        worktree: worktree,
                        reportID: reportID
                    )
                    return .launchFailed(reason)
                }
                var notificationText = "\(schedule.name): agent task completed. Report: \(reportID)."
                var notificationSeverity = InAppNotificationSeverity.success
                if report.cleanupRequested {
                    let cleanupResult: ScheduledWorktreeCleanupResult
                    if case .settledWithUnrelatedPrompt = settlement {
                        let reason = "A non-scheduled ACP prompt was queued during the scheduled turn."
                        cleanupResult = await retainScheduledWorktree(
                            reportID: reportID,
                            reason: reason,
                            store: store
                        )
                    } else if let registration = activeScheduledAgentRunsBySession[prepared.sessionID],
                              registration.reportID == reportID {
                        cleanupResult = await cleanupScheduledAgentWorktree(
                            report: report,
                            registration: registration,
                            project: project,
                            worktree: worktree,
                            store: store
                        )
                    } else {
                        let reason = "The scheduled ACP session is no longer active."
                        cleanupResult = await persistScheduledCleanupState(
                            reportID: reportID,
                            state: .retained,
                            reason: reason,
                            store: store
                        ) ? .retained(reason) : .failed(
                            reason: "The worktree was retained, but its cleanup status could not be saved.",
                            worktreeRemoved: false
                        )
                    }
                    switch cleanupResult {
                    case .removed:
                        notificationText = "\(schedule.name): agent task completed and its worktree was removed. Report: \(reportID)."
                    case .retained(let reason):
                        notificationText = "\(schedule.name): agent task completed; worktree retained. \(reason) Report: \(reportID)."
                        notificationSeverity = .information
                    case .failed(let reason, _):
                        notificationText = "\(schedule.name): agent task completed, but worktree cleanup failed. \(reason) Report: \(reportID)."
                        notificationSeverity = .information
                    }
                }
                let notificationWorktreeID = selectedWorktreeId
                    ?? projectsManager.visibleMainWorktree(projectId: project.id)?.id
                    ?? worktree.id
                inAppNotifications.post(
                    notificationText,
                    severity: notificationSeverity,
                    worktreeID: notificationWorktreeID,
                    actionTitle: "Open report",
                    action: scheduledAgentReportOpenAction(reportID)
                )
                return .succeeded
            } catch {
                let reason = "Could not finalize the scheduled-agent report; the report was not committed and the worktree was retained."
                reportScheduleFailure(
                    schedule,
                    reason: "\(reason) Report: \(reportID).",
                    project: project,
                    worktree: worktree,
                    reportID: reportID
                )
                return .launchFailed(reason)
            }
        }
    }

    /// Atomically checks and claims on the main actor; callers must not await
    /// between observing an idle worktree and installing the delete claim.
    func claimScheduledAgentWorktreeForCleanup(_ worktree: Worktree) -> Bool {
        guard projectsManager.operationState(for: worktree) == nil else { return false }
        projectsManager.setOperationState(
            for: worktree,
            state: .deleting(projectId: worktree.projectId)
        )
        return true
    }

    private func cleanupScheduledAgentWorktree(
        report: ScheduledAgentReport,
        registration: ScheduledAgentRunRegistration,
        project: ProjectConfig,
        worktree: Worktree,
        store: ScheduledAgentReportStore
    ) async -> ScheduledWorktreeCleanupResult {
        guard report.cleanupRequested,
              report.cleanupState == .pending,
              report.taskState == .succeeded
        else {
            return .failed(reason: "The report is not in a cleanable state.", worktreeRemoved: false)
        }
        guard claimScheduledAgentWorktreeForCleanup(worktree) else {
            return await retainScheduledWorktree(
                reportID: report.id,
                reason: "The worktree is already being changed.",
                store: store
            )
        }
        let initialCheck = await scheduledWorktreeCleanupCheck(
            report: report,
            registration: registration,
            project: project,
            worktree: worktree,
            expectedFingerprint: nil,
            deletionClaimed: true,
            sessionDisposed: false
        )
        guard case .allowed(let initialFingerprint) = initialCheck else {
            let reason: String
            if case .refused(let refusal) = initialCheck {
                reason = refusal
            } else {
                reason = "The worktree changed while cleanup was being checked."
            }
            projectsManager.setOperationState(for: worktree, state: nil)
            return await retainScheduledWorktree(reportID: report.id, reason: reason, store: store)
        }

        let claimedCheck = await scheduledWorktreeCleanupCheck(
            report: report,
            registration: registration,
            project: project,
            worktree: worktree,
            expectedFingerprint: initialFingerprint,
            deletionClaimed: true,
            sessionDisposed: false
        )
        guard case .allowed(let claimedFingerprint) = claimedCheck else {
            let reason: String
            if case .refused(let refusal) = claimedCheck {
                reason = refusal
            } else {
                reason = "The worktree changed while cleanup was being checked."
            }
            projectsManager.setOperationState(for: worktree, state: nil)
            return await retainScheduledWorktree(reportID: report.id, reason: reason, store: store)
        }

        guard acpManager(forWorktreeId: worktree.id) != nil else {
            projectsManager.setOperationState(for: worktree, state: nil)
            return await retainScheduledWorktree(
                reportID: report.id,
                reason: "The scheduled ACP session manager is no longer available.",
                store: store
            )
        }
        let scheduledScriptTerminal = Self.scheduledScriptTerminalForCleanup(
            report: report,
            worktree: worktree,
            runRecords: runRecords,
            tabs: tabs.tabs(forWorktree: worktree.id)
        )
        let sessionTabIDs = tabs.tabs(forWorktree: worktree.id).compactMap { tab -> TabID? in
            guard case .acpSession(let state) = tab,
                  state.sessionId == registration.sessionID
            else { return nil }
            return tab.id
        }
        closeCenterTabs(
            worktreeId: worktree.id,
            projectId: project.id,
            tabIds: sessionTabIDs
        )
        if let scheduledScriptTerminal {
            // A persistent (zmx-wrapped) terminal is provably terminated by
            // `terminateSessionsAndWait`. A plain Ghostty shell
            // (keepSessionsAlive off) has no zmx session: nothing proves its
            // process — or anything it spawned — stopped writing, and
            // closing the tab only releases the lease while the kill is
            // dispatched asynchronously. Retain the worktree in that case.
            if terminal.registry.session(for: scheduledScriptTerminal.sessionID)?.zmxSessionName == nil {
                projectsManager.setOperationState(for: worktree, state: nil)
                return await retainScheduledWorktree(
                    reportID: report.id,
                    reason: "The scheduled script terminal cannot be verified stopped; it has no persistent session.",
                    store: store
                )
            }
            let projectPath = project.path
            do {
                try await terminal.terminateSessionsAndWait(
                    [
                        TerminalSessionIdentity(
                            worktreeId: worktree.id,
                            projectPath: projectPath,
                            leafId: scheduledScriptTerminal.sessionID
                        )
                    ],
                    timeout: 5
                )
            } catch is TerminalService.SessionTerminationError {
                projectsManager.setOperationState(for: worktree, state: nil)
                return await retainScheduledWorktree(
                    reportID: report.id,
                    reason: "The scheduled script terminal did not terminate.",
                    store: store
                )
            } catch {
                projectsManager.setOperationState(for: worktree, state: nil)
                return await retainScheduledWorktree(
                    reportID: report.id,
                    reason: "The scheduled script terminal could not be terminated.",
                    store: store
                )
            }
            closeTab(worktreeId: worktree.id, tabId: scheduledScriptTerminal.tabID)
        } else if report.scriptRun != nil {
            // The tab is gone (the user closed it), but the run record's
            // shell may still be alive: `closeSession` released the lease
            // and dispatched its zmx kill asynchronously, so a hung or
            // failed kill leaves a shell that no session or lease check
            // can see. Whether the run was persistent is not recorded, so
            // zmx absence alone cannot prove a plain Ghostty process
            // stopped: verify the derived zmx session is gone when zmx is
            // available, and retain in every other case.
            if let scriptRun = report.scriptRun,
               let record = runRecords.records(worktreeID: worktree.id).first(where: {
                   $0.id == scriptRun.runID
                       && $0.scriptName == scriptRun.scriptName
                       && $0.branch == worktree.branch
               }),
               let sessionID = record.sessionID {
                let identity = TerminalSessionIdentity(
                    worktreeId: worktree.id,
                    projectPath: project.path,
                    leafId: sessionID
                )
                let derivedName = identity.zmxSessionName
                guard let liveNames = await terminal.zmxSessionNamesIfVerified() else {
                    // Enumeration failure is not proof of absence: the shell
                    // may still be alive and invisible to the session and
                    // lease checks.
                    projectsManager.setOperationState(for: worktree, state: nil)
                    return await retainScheduledWorktree(
                        reportID: report.id,
                        reason: "Could not verify the scheduled script session is stopped; zmx enumeration failed.",
                        store: store
                    )
                }
                if liveNames.contains(derivedName) {
                    projectsManager.setOperationState(for: worktree, state: nil)
                    return await retainScheduledWorktree(
                        reportID: report.id,
                        reason: "The scheduled script session is still alive after its tab was closed.",
                        store: store
                    )
                }
                // A plain (non-persistent) shell was never registered with
                // zmx, so its absence there proves nothing. Its lease was
                // already released when the tab closed and nothing can
                // verify the process stopped, so retain conservatively.
                projectsManager.setOperationState(for: worktree, state: nil)
                return await retainScheduledWorktree(
                    reportID: report.id,
                    reason: "The scheduled script terminal was closed before cleanup; its shell could not be verified stopped.",
                    store: store
                )
            } else {
                projectsManager.setOperationState(for: worktree, state: nil)
                return await retainScheduledWorktree(
                    reportID: report.id,
                    reason: "The scheduled script terminal could not be identified for cleanup.",
                    store: store
                )
            }
        }
        await disposeACPManagerAndWait(owner: .worktree(worktree.id))
        let sessionPersistence = ACPSessionPersistence(
            path: Paths.acpSessionsDB(forWorktreeId: worktree.id).path
        )
        do {
            guard try await sessionPersistence.loadQueue(sessionId: registration.sessionID).isEmpty else {
                projectsManager.setOperationState(for: worktree, state: nil)
                return await retainScheduledWorktree(
                    reportID: report.id,
                    reason: "The scheduled ACP session still has queued work.",
                    store: store
                )
            }
        } catch {
            projectsManager.setOperationState(for: worktree, state: nil)
            return await retainScheduledWorktree(
                reportID: report.id,
                reason: "Could not verify the scheduled ACP session queue.",
                store: store
            )
        }

        let finalCheck = await scheduledWorktreeCleanupCheck(
            report: report,
            registration: registration,
            project: project,
            worktree: worktree,
            expectedFingerprint: claimedFingerprint,
            deletionClaimed: true,
            sessionDisposed: true
        )
        guard case .allowed(let finalFingerprint) = finalCheck,
              finalFingerprint == claimedFingerprint
        else {
            let reason: String
            if case .refused(let refusal) = finalCheck {
                reason = refusal
            } else {
                reason = "Git content changed while cleanup was being prepared."
            }
            projectsManager.setOperationState(for: worktree, state: nil)
            return await retainScheduledWorktree(reportID: report.id, reason: reason, store: store)
        }

        var authorizedSessionIDs: Set<String> = [registration.sessionID]
        if let scheduledScriptTerminal {
            authorizedSessionIDs.insert(scheduledScriptTerminal.sessionID)
        }
        let siblings = projectsManager.visibleWorktrees(projectId: project.id)
        let removedIndex = siblings.firstIndex(where: { $0.id == worktree.id }) ?? 0
        let outcome = await performDeleteWorktree(
            worktree: worktree,
            repoPath: URL(fileURLWithPath: project.path),
            deleteBranchIfMerged: false,
            force: false,
            removedIndex: removedIndex,
            promptsForForce: false,
            authorizedDeleteContentFingerprint: finalFingerprint,
            authorizedWorktreeLineageID: registration.worktreeLineageID,
            authorizedDirtyTabsAtConfirmation: [:],
            authorizedSessionIDs: authorizedSessionIDs,
            scheduledCleanupLeaseCheck: { [weak self] in
                guard let self,
                      let lineageID = registration.worktreeLineageID
                else {
                    return false
                }
                return self.scheduledCleanupHasNoOtherWriterLeases(
                    for: worktree,
                    lineageID: lineageID
                )
            }
        )
        switch outcome {
        case .deleted:
            await disposeACPManagerAndWait(owner: .worktree(worktree.id))
            do {
                try await sessionPersistence.deleteSession(id: registration.sessionID)
            } catch {
                let reason = "The worktree was removed, but the scheduled ACP session row could not be deleted."
                _ = await persistScheduledCleanupState(
                    reportID: report.id,
                    state: .failed,
                    reason: reason,
                    store: store
                )
                return .failed(reason: reason, worktreeRemoved: true)
            }
            do {
                _ = try await store.updateCleanup(reportID: report.id, state: .removed)
                return .removed
            } catch {
                return .failed(
                    reason: "The worktree and ACP session were removed, but the report could not record cleanup.",
                    worktreeRemoved: true
                )
            }
        case .needsForce:
            return await retainScheduledWorktree(
                reportID: report.id,
                reason: "Git refused non-force removal; automatic cleanup never retries with force.",
                store: store
            )
        case .skipped(let reason):
            return await retainScheduledWorktree(
                reportID: report.id,
                reason: "The worktree changed before removal: \(reason)",
                store: store
            )
        case .failed(let message):
            let reason = "Git could not remove the worktree safely: \(message)"
            guard await persistScheduledCleanupState(
                reportID: report.id,
                state: .failed,
                reason: reason,
                store: store
            ) else {
                return .failed(
                    reason: "Git could not remove the worktree and the report could not record cleanup.",
                    worktreeRemoved: false
                )
            }
            return .failed(reason: reason, worktreeRemoved: false)
        case .archived:
            return await retainScheduledWorktree(
                reportID: report.id,
                reason: "The worktree was not removed.",
                store: store
            )
        }
    }

    static func scheduledAgentCleanupIdentityIsValid(
        report: ScheduledAgentReport,
        registration: ScheduledAgentRunRegistration,
        project: ProjectConfig,
        worktree: Worktree
    ) -> Bool {
        report.id == registration.reportID
            && report.occurrenceID == registration.occurrenceID
            && report.scheduleID == registration.scheduleID
            && report.projectID == project.id
            && report.projectID == registration.projectID
            && report.worktreeID == worktree.id
            && report.worktreeID == registration.worktreeID
            && report.branch == worktree.branch
            && report.sessionID == registration.sessionID
            && registration.worktreeLineageID != nil
            && registration.worktreeLineageID == worktree.lineageID
            && report.cleanupState == .pending
    }

    static func scheduledCleanupHasNoOtherSessions(
        worktreeSessionIDs: Set<String>,
        managerSessionIDs: Set<String>,
        scheduledSessionID: String,
        scheduledScriptSessionID: String? = nil
    ) -> Bool {
        var otherSessionIDs = worktreeSessionIDs
        otherSessionIDs.formUnion(managerSessionIDs)
        otherSessionIDs.remove(scheduledSessionID)
        if let scheduledScriptSessionID {
            otherSessionIDs.remove(scheduledScriptSessionID)
        }
        return otherSessionIDs.isEmpty
    }

    static func scheduledCleanupSessionIsQuiescent(_ session: ACPSession) -> Bool {
        session.queue.isEmpty
            && session.composerDraft.isEmpty
            && session.transcript.streamingState == .idle
            && session.transcript.pendingPermission == nil
            && session.transcript.pendingQuestion == nil
            && session.transcript.pendingUserInputs.isEmpty
    }

    /// Return only the finished scheduled script's sole terminal leaf; split
    /// or unrelated panes remain blockers rather than being closed.
    static func scheduledScriptTerminalForCleanup(
        report: ScheduledAgentReport,
        worktree: Worktree,
        runRecords: RunRecordStore,
        tabs: [Tab]
    ) -> (tabID: TabID, sessionID: String)? {
        guard let scriptRun = report.scriptRun,
              report.worktreeID == worktree.id,
              scriptRun.worktreeID == worktree.id,
              scriptRun.branch == worktree.branch,
              let record = runRecords.records(worktreeID: worktree.id).first(where: {
                  $0.id == scriptRun.runID
                      && $0.scriptName == scriptRun.scriptName
                      && $0.branch == worktree.branch
              }),
              case .finished(.succeeded) = record.status,
              let sessionID = record.sessionID,
              let tab = tabs.first(where: { tab in
                  guard case .terminal(let state) = tab,
                        state.runScriptKey == record.scriptKey,
                        state.runScriptLeafId == sessionID
                  else {
                      return false
                  }
                  let leaves = state.root.leaves()
                  return leaves.count == 1 && leaves[0].sessionId == sessionID
              })
        else {
            return nil
        }
        return (tab.id, sessionID)
    }

    private func scheduledWorktreeCleanupCheck(
        report: ScheduledAgentReport,
        registration: ScheduledAgentRunRegistration,
        project: ProjectConfig,
        worktree: Worktree,
        expectedFingerprint: String?,
        deletionClaimed: Bool,
        sessionDisposed: Bool
    ) async -> ScheduledWorktreeCleanupCheck {
        let expectedOperationState: WorktreeOperationState? = deletionClaimed
            ? .deleting(projectId: worktree.projectId)
            : nil
        func volatileStateIsSafe() -> Bool {
            guard let capturedLineageID = registration.worktreeLineageID,
                  WorktreeService.existingLocalLineageID(forWorktreeAt: worktree.path) == capturedLineageID,
                  !Task.isCancelled,
                  activeScheduledAgentRunsBySession[registration.sessionID] === registration,
                  Self.scheduledAgentCleanupIdentityIsValid(
                      report: report,
                      registration: registration,
                      project: project,
                      worktree: worktree
                  ),
                  projectsManager.operationState(for: worktree) == expectedOperationState,
                  projectsManager.visibleMainWorktree(projectId: project.id)?.id != worktree.id,
                  projectsManager.visibleWorktrees(projectId: project.id).contains(where: {
                      $0.id == worktree.id
                          && $0.path.standardizedFileURL == worktree.path.standardizedFileURL
                          && $0.branch == worktree.branch
                  }),
                  let currentProject = projects.first(where: { $0.id == project.id }),
                  currentProject.path == project.path,
                  currentProject.host == nil,
                  project.host == nil,
                  Self.workspaceCleanupOwnershipAvailable(
                      workspacesEnabled: config.workspacesEnabled,
                      workspacesCanMutate: workspacesManager.canMutate
                  ),
                  worktreeCleanupWorkspaceOwners(for: worktree).isEmpty,
                  dirtyTabGenerations(worktreeId: worktree.id).isEmpty
            else {
                return false
            }

            guard scheduledCleanupHasNoOtherWriterLeases(
                for: worktree,
                lineageID: capturedLineageID
            ) else {
                return false
            }

            let tabSessionIDs = worktreeCleanupSessionIDs(worktreeId: worktree.id)
            if sessionDisposed {
                return acpManager(forWorktreeId: worktree.id) == nil && tabSessionIDs.isEmpty
            }
            guard let manager = acpManager(forWorktreeId: worktree.id),
                  let session = manager.liveSession(for: registration.sessionID),
                  isWriter(for: registration.sessionID)
            else {
                return false
            }
            let builtInMCPIsRequested = session.mcpAttachmentSummary?.statuses.contains { status in
                guard status.id == BuiltInAlasMCP.statusId else { return false }
                if case .requested = status.disposition { return true }
                return false
            } == true
            let scheduledScriptSessionID = Self.scheduledScriptTerminalForCleanup(
                report: report,
                worktree: worktree,
                runRecords: runRecords,
                tabs: tabs.tabs(forWorktree: worktree.id)
            )?.sessionID
            return Self.scheduledCleanupHasNoOtherSessions(
                worktreeSessionIDs: tabSessionIDs,
                managerSessionIDs: Set(manager.sessions.keys),
                scheduledSessionID: registration.sessionID,
                scheduledScriptSessionID: scheduledScriptSessionID
            )
                && session.agentState == .ready
                && session.setupState == .ready
                && Self.scheduledCleanupSessionIsQuiescent(session)
                && builtInMCPIsRequested
                && session.builtInMCPRegistration == .registered
                && registration.completion?.outcome == .succeeded
        }

        guard volatileStateIsSafe() else {
            return .refused("Worktree, session, or application state changed before cleanup.")
        }
        guard await !checkpointWorktreeRemovalDisabledAfterDiscovery(worktree) else {
            return .refused(Self.checkpointRecoveryBlocksWorktreeRemovalMessage)
        }
        do {
            let preflight = try await WorktreeService().deletePreflight(
                worktreePath: worktree.path,
                usesRemoteHostRegistry: false
            )
            guard !preflight.requiresForce else {
                return .refused("The worktree has local changes or is Git-locked.")
            }
            let fingerprint = try await WorktreeService.worktreeDeleteContentFingerprint(
                worktreePath: worktree.path
            )
            if let expectedFingerprint, expectedFingerprint != fingerprint {
                return .refused("Git content changed while cleanup was being prepared.")
            }
            // Ignored paths never show up in the preflight's clean check or
            // the fingerprint's untracked inventory, but a non-force
            // `git worktree remove` deletes them. Unattended cleanup must
            // not destroy an ignored artifact's only copy.
            guard try await !WorktreeService.worktreeHasIgnoredContent(
                worktreePath: worktree.path
            ) else {
                return .refused("The worktree holds ignored files that cleanup would delete.")
            }
            guard let baseCommit = report.baseCommit,
                  try await WorktreeService.scheduledCleanupHistoryIsSafe(
                      baseCommit: baseCommit,
                      expectedBranch: worktree.branch,
                      worktreePath: worktree.path
                  )
            else {
                return .refused("The current branch has commits not reachable from a remote-tracking branch.")
            }
            guard volatileStateIsSafe() else {
                return .refused("Worktree, session, or application state changed during cleanup checks.")
            }
            // A terminal closed moments ago (e.g. by the user, unrelated to
            // the scheduled session) had its writer lease released before
            // its zmx kill finished dispatching. A slow or failed kill
            // leaves a shell invisible to the session and lease checks
            // above, so cleanup must positively await the pending kills and
            // only proceed when every recent termination was verified.
            let unverifiedKills = await terminal.awaitAndVerifyRecentTerminalKills(
                within: 15,
                timeout: 5,
                restrictToWorktree: worktree.id
            )
            if !unverifiedKills.isEmpty {
                return .refused("A recently closed terminal did not confirm its termination.")
            }
            return .allowed(contentFingerprint: fingerprint)
        } catch {
            return .refused("Git could not verify the worktree safety checks.")
        }
    }

    private func retainScheduledWorktree(
        reportID: String,
        reason: String,
        store: ScheduledAgentReportStore
    ) async -> ScheduledWorktreeCleanupResult {
        guard await persistScheduledCleanupState(
            reportID: reportID,
            state: .retained,
            reason: reason,
            store: store
        ) else {
            return .failed(
                reason: "The worktree was retained, but the report could not save the cleanup state.",
                worktreeRemoved: false
            )
        }
        return .retained(reason)
    }

    private func persistScheduledCleanupState(
        reportID: String,
        state: ScheduledAgentCleanupState,
        reason: String,
        store: ScheduledAgentReportStore
    ) async -> Bool {
        do {
            _ = try await store.updateCleanup(reportID: reportID, state: state, reason: reason)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Prompt delivery

    /// How long to wait for the agent to appear in its terminal before giving
    /// up on the prompt. Generous because the startup script runs first and
    /// a remote host may still be attaching its session.
    static let scheduledPromptReadinessTimeout: TimeInterval = 120
    /// Pause between the agent appearing and the first keystroke, so a TUI
    /// has drawn its input box before text arrives in it.
    static let scheduledPromptSettleDelay: Duration = .milliseconds(1_500)
    /// Pause between the prompt and the Enter that submits it, so an input
    /// that debounces paste-like bursts sees them as two events.
    static let scheduledPromptSubmitDelay: Duration = .milliseconds(200)

    /// Types the prompt into the agent's terminal, and Enter after it when
    /// the schedule asks for that. Never types into a terminal whose agent
    /// has not been seen: the shell would receive the text instead, and with
    /// auto-send would run it. That failure is reported but does not undo the
    /// launch, which did happen.
    private func deliverScheduledPrompt(
        _ prompt: String,
        sendsAutomatically: Bool,
        sessionID: String,
        schedule: RunSchedule,
        worktree: Worktree,
        host: String?,
        agentID: String
    ) async {
        let text = RunScheduleComposition.terminalText(for: prompt)
        guard !text.isEmpty else { return }
        // Said and dropped immediately rather than waiting out the timeout:
        // on a remote project the readiness signal can never arrive, so the
        // wait would burn two minutes per firing to reach the same place.
        guard RunSchedulePresentation.deliversPrompt(host: host) else {
            inAppNotifications.post(
                RunSchedulePresentation.remotePromptSkippedMessage(
                    scheduleName: schedule.name,
                    host: host ?? ""
                ),
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        guard await waitForScheduledAgent(sessionID: sessionID, expecting: agentID) else {
            // A cancelled delivery is not a failed one. The schedule was
            // deleted or torn down, and reporting that its agent never got
            // ready would be noise about work the user called off.
            guard !Task.isCancelled else { return }
            inAppNotifications.post(
                "\(schedule.name): could not confirm the agent was ready in \(worktree.branch), so the prompt was not sent.",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        // Same race as the one guarded before Enter: the settle sleep can
        // finish and the schedule be deleted before this resumes on the main
        // actor, in which case nothing threw and the wait reported ready.
        guard !Task.isCancelled else { return }
        guard typeIntoTerminal(text, sessionID: sessionID) else {
            inAppNotifications.post(
                "\(schedule.name): the agent's terminal in \(worktree.branch) closed before the prompt could be sent.",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        guard sendsAutomatically else { return }
        // Cancellation here means the schedule was deleted or torn down
        // between the prompt and its Enter. Submitting anyway would start
        // the very work that was just called off, so the typed text is left
        // sitting in the input instead.
        do {
            try await Task.sleep(for: Self.scheduledPromptSubmitDelay)
        } catch {
            return
        }
        // The agent can also die inside that pause, leaving the shell to
        // reclaim the terminal. Enter would then run whatever of the prompt
        // the agent had not consumed as a command, so ownership is confirmed
        // once more before submitting.
        guard await scheduledAgentOwnsTerminal(sessionID: sessionID, agentID: agentID) else {
            inAppNotifications.post(
                "\(schedule.name): the agent stopped before the prompt could be submitted in \(worktree.branch).",
                severity: .error,
                worktreeID: worktree.id
            )
            return
        }
        // Last, so that nothing suspends between these two answers and the
        // write they guard. Cancellation can otherwise land after the sleep
        // returned or during the ownership hop, both of which bypass the
        // catch above and would submit for a schedule already gone.
        guard !Task.isCancelled else { return }
        _ = typeIntoTerminal("\r", sessionID: sessionID)
    }

    /// Ready means the detector currently sees *this schedule's* agent as
    /// the session's foreground process.
    ///
    /// The identity check matters because the user's session-open script
    /// runs ahead of the agent command in the same shell. A script that
    /// launches some other recognised harness and stays running would
    /// otherwise collect the prompt, and with auto-send have it submitted,
    /// while the scheduled agent had not started yet.
    ///
    /// An agent whose harness cannot be named at all is refused rather than
    /// accepting whatever else the detector happens to see. Nothing is lost:
    /// the detector recognises a fixed set of binaries, so such an agent
    /// could never have been confirmed anyway.
    ///
    /// `activeHarnessBySession` rather than `harnessBySession`: the latter is
    /// never cleared when the process exits, so it answers "did an agent ever
    /// run here", which stays true for the shell that reclaims the terminal
    /// afterwards.
    ///
    /// Cancellation ends the wait instead of being swallowed. A cancelled
    /// sleep returns immediately, so ignoring it would spin this loop on the
    /// main actor until the deadline and freeze the app.
    private func waitForScheduledAgent(sessionID: String, expecting agentID: String) async -> Bool {
        if let scheduledAgentReadiness {
            return await scheduledAgentReadiness(sessionID)
        }
        guard let expected = expectedHarness(forAgentID: agentID) else { return false }
        let deadline = Date().addingTimeInterval(Self.scheduledPromptReadinessTimeout)
        while harness.activeHarnessBySession[sessionID] != expected {
            guard Date() < deadline, harness.detector.isRegistered(sessionId: sessionID) else { return false }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return false
            }
        }
        // The agent can still exit while the TUI is settling, and the
        // terminal outlives it. Re-ask rather than trusting the earlier
        // sighting: typing into the shell that took the session back would,
        // with auto-send, run the prompt as a command. Asked live, because
        // the poll behind the loop above only refreshes once a second and
        // the caller writes the moment this returns.
        do {
            try await Task.sleep(for: Self.scheduledPromptSettleDelay)
        } catch {
            return false
        }
        return await scheduledAgentOwnsTerminal(sessionID: sessionID, agentID: agentID)
    }

    /// Whether the schedule's agent is, at this instant, the foreground
    /// process of that terminal. Asked immediately before each write,
    /// because the gap around them is long enough for the agent to die and
    /// the shell to take the session back.
    ///
    /// The session's pid is read and classified here rather than reading
    /// `activeHarnessBySession`. That map is refreshed by a poll that runs
    /// once a second, so it can be a whole second out of date — several
    /// times the pause before Enter, and the entire window this check
    /// exists to cover.
    private func scheduledAgentOwnsTerminal(sessionID: String, agentID: String) async -> Bool {
        // The readiness seam replaces the detector wholesale in tests, whose
        // sessions have no process to observe.
        if scheduledAgentReadiness != nil { return true }
        guard let expected = expectedHarness(forAgentID: agentID),
              let pid = harness.detector.foregroundPid(sessionId: sessionID)
        else { return false }
        // Resolving a pid to an executable is a syscall, and `HarnessDetector`
        // keeps it off the main thread for exactly that reason. The hop costs
        // far less than the second of staleness this replaced, so the answer
        // is still current by the time the caller writes.
        let detected = await Task.detached { HarnessDetector.matchKind(pid: pid) }.value
        return detected == expected
    }

    /// Which harness the schedule's agent will appear as in its terminal, or
    /// nil when nothing about it is recognisable and readiness therefore
    /// cannot be established.
    private func expectedHarness(forAgentID agentID: String) -> HarnessKind? {
        guard let agent = agentRegistry.agents.first(where: { $0.id == agentID }) else {
            return HarnessKind.forAgentID(agentID)
        }
        return HarnessKind.forAgent(id: agentID, binary: agent.configuredBinary)
    }

    private func typeIntoTerminal(_ text: String, sessionID: String) -> Bool {
        if let terminalTextSender {
            return terminalTextSender(sessionID, text)
        }
        guard let session = terminal.registry.session(for: sessionID) else { return false }
        session.surface.sendText(text)
        return true
    }
}
