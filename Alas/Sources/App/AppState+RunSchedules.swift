import Foundation
import os

private let runScheduleLogger = Logger(subsystem: "io.nlopez.alas", category: "RunSchedules")

/// How a launched script settled. Delivered exactly once per run ID to
/// whoever asked to be told, which today is only the scheduler.
enum RunScriptSettlement: Equatable, Sendable {
    case finished(RunOutcome)
    /// The command never started (terminal failed to open, shell rejected).
    case launchFailed(String)
}

extension AppState {
    // MARK: - Wiring

    func installRunScheduleRunner() {
        runScheduler.runner = { [weak self] schedule, invocation in
            guard let self else {
                return RunScheduleRunReport(outcome: .launchFailed("Alas is shutting down."))
            }
            return await self.runSchedule(schedule, invocation: invocation)
        }
    }

    /// Starts the scheduler only while its preview flag is on. Called once
    /// the worktree topology is loaded, because schedules resolve their
    /// targets against it.
    func startRunSchedulerIfEnabled() {
        guard config.schedulesEnabled else { return }
        runScheduler.start()
    }

    /// Turning the flag off stops the clock outright: no evaluation, no
    /// firing, and no pane left showing a gated tab. Saved schedules are kept
    /// so switching it back on restores them.
    func setSchedulesEnabled(_ enabled: Bool) {
        guard config.schedulesEnabled != enabled else { return }
        config.schedulesEnabled = enabled
        saveConfig()
        if enabled {
            runScheduler.start()
        } else {
            runScheduler.stop()
            rightPaneStore.retreatFromTab(.schedules)
        }
    }

    // MARK: - Execution

    /// Runs a schedule once. Every step reuses the manual path: worktree
    /// creation goes through `createWorktreeAndWait`, the script through the
    /// same launch used by the Run tab, and the agent through the worktree
    /// launch surface. The returned outcome is what the schedule row shows.
    func runSchedule(
        _ schedule: RunSchedule,
        invocation: RunScheduleInvocation = .scheduled
    ) async -> RunScheduleRunReport {
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
                await self.runSchedule(schedule, project: target.project, worktree: target.worktree)
            }
        }
        var outcomes: [RunScheduleOutcome] = []
        var references: [RunScheduleFiring.RunReference] = []
        for run in runs {
            let report = await run.value
            outcomes.append(report.outcome)
            references.append(contentsOf: report.runs)
        }
        // Every target's run is linked, not just the one whose outcome won:
        // a fan-out that failed in one project should still let the user open
        // the reports of the projects that did run.
        return RunScheduleRunReport(outcome: .combined(outcomes), runs: references)
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
        worktree originWorktree: Worktree
    ) async -> RunScheduleRunReport {
        var worktree = originWorktree
        if let composition = schedule.composition {
            switch await createScheduledWorktree(for: schedule, composition: composition, project: project) {
            case .success(let created):
                worktree = created
            case .failure(let failure):
                reportScheduleFailure(
                    schedule, reason: failure.message, project: project, worktree: originWorktree
                )
                return RunScheduleRunReport(outcome: .launchFailed(failure.message))
            }
        }

        var references: [RunScheduleFiring.RunReference] = []
        if let scriptKey = schedule.scriptKey {
            let script = await runScheduledScript(key: scriptKey, in: worktree, project: project)
            // Kept even when the script failed: a failed run is exactly the
            // one whose report the user wants to open from the history.
            references = script.runs
            guard case .succeeded = script.outcome else {
                switch script.outcome {
                case .skipped:
                    // Nothing was launched, so there is nothing to compose on.
                    break
                case .launchFailed(let message):
                    // The command never started, so no run-script completion
                    // notification will ever mention it.
                    reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
                default:
                    if schedule.composition != nil {
                        inAppNotifications.post(
                            "\(schedule.name): script did not succeed, agent not launched.",
                            severity: .error,
                            worktreeID: worktree.id
                        )
                    }
                }
                return RunScheduleRunReport(outcome: script.outcome, runs: references)
            }
        }

        guard let composition = schedule.composition else {
            return RunScheduleRunReport(outcome: .succeeded, runs: references)
        }
        let agent = await launchScheduledAgent(
            for: schedule, composition: composition, worktree: worktree, project: project
        )
        return RunScheduleRunReport(outcome: agent, runs: references)
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
        worktree: Worktree
    ) {
        inAppNotifications.post("\(schedule.name): \(reason)", severity: .error, worktreeID: worktree.id)
        harness.notifications.notifyScheduleFailed(
            scheduleName: schedule.name,
            reason: reason,
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
        // and every later one would fail on the existing destination.
        guard let free = firstFreeScheduledBranch(rendered, project: project) else {
            return .failure(.init(
                message: "Could not find a free worktree path for \(rendered); clean up old scheduled worktrees."
            ))
        }
        let branch = free.branch
        let destination = free.destination
        let availableBranches = (try? await GitService().branches(at: URL(fileURLWithPath: project.path))) ?? []
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

    /// The rendered branch if its destination is free, else the same name
    /// with the smallest numeric suffix that is. Nil when the whole run is
    /// taken, which means the user has scheduled worktrees to clean up.
    private func firstFreeScheduledBranch(
        _ rendered: String,
        project: ProjectConfig,
        limit: Int = 50
    ) -> (branch: String, destination: URL)? {
        for attempt in 0..<limit {
            let branch = attempt == 0 ? rendered : "\(rendered)-\(attempt + 1)"
            guard case .valid = GitNameValidator.validateBranchName(branch) else { continue }
            let destination = WorktreePathTemplateRenderer.render(
                template: config.worktrees.pathTemplate,
                worktreeRoot: config.worktrees.rootPath,
                repoName: project.name,
                branch: branch
            )
            if !FileManager.default.fileExists(atPath: destination.path) {
                return (branch, destination)
            }
        }
        return nil
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
        let settlement: RunScriptSettlement = await withCheckedContinuation { continuation in
            switch startScriptLaunch(script, in: worktree, presentsLaunchFailure: false) {
            case .started(let runID):
                reference = RunScheduleFiring.RunReference(
                    worktreeID: worktree.id,
                    branch: worktree.branch,
                    runID: runID,
                    scriptName: script.displayName
                )
                awaitRunScriptSettlement(runID: runID, worktreeID: worktree.id) {
                    continuation.resume(returning: $0)
                }
            case .alreadyStarting:
                continuation.resume(returning: .launchFailed("\(script.displayName) is already starting in \(worktree.branch)."))
            case .projectUnavailable:
                continuation.resume(returning: .launchFailed("The project is no longer available."))
            case let .refused(_, message):
                continuation.resume(returning: .launchFailed(message))
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
        }
    }

    private func launchScheduledAgent(
        for schedule: RunSchedule,
        composition: RunScheduleComposition,
        worktree: Worktree,
        project: ProjectConfig
    ) async -> RunScheduleOutcome {
        let agentId = composition.agentId ?? defaultAgentID(projectId: project.id, worktreeRoot: worktree.path)
        guard let agentId else {
            let message = "No agent is configured to launch for \(project.name)."
            reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
            return .launchFailed(message)
        }
        let launchSurface = WorktreeLaunchSurface.terminal(agentId: agentId)
        do {
            try await launchWorktreeSurface(launchSurface, worktree: worktree, project: project)
        } catch {
            markWorktreeLaunchFailed(
                worktree: worktree,
                projectId: project.id,
                error: error,
                launchSurface: launchSurface
            )
            reportScheduleFailure(
                schedule, reason: error.localizedDescription, project: project, worktree: worktree
            )
            runScheduleLogger.error(
                "Scheduled agent launch failed for \(schedule.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return .launchFailed(error.localizedDescription)
        }
        let agentName = agentRegistry.agents.first { $0.id == agentId }?.displayName ?? agentId
        inAppNotifications.post(
            "\(schedule.name): launched \(agentName) in \(worktree.branch)",
            severity: .success,
            worktreeID: worktree.id
        )
        return .succeeded
    }
}
