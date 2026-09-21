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
            guard let self else { return .launchFailed("Alas is shutting down.") }
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
    ) async -> RunScheduleOutcome {
        let targets: [(project: ProjectConfig, worktree: Worktree)]
        switch resolveScheduleTargets(schedule.target, invocation: invocation) {
        case .targets(let resolved):
            targets = resolved
        case .unavailable(let reason):
            return .skipped(reason: reason)
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
        for run in runs {
            outcomes.append(await run.value)
        }
        return RunScheduleOutcome.combined(outcomes)
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
    ) async -> RunScheduleOutcome {
        var worktree = originWorktree
        if let composition = schedule.composition {
            switch await createScheduledWorktree(for: schedule, composition: composition, project: project) {
            case .success(let created):
                worktree = created
            case .failure(let failure):
                reportScheduleFailure(
                    schedule, reason: failure.message, project: project, worktree: originWorktree
                )
                return .launchFailed(failure.message)
            }
        }

        if let scriptKey = schedule.scriptKey {
            let scriptOutcome = await runScheduledScript(key: scriptKey, in: worktree, project: project)
            guard case .succeeded = scriptOutcome else {
                switch scriptOutcome {
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
                return scriptOutcome
            }
        }

        guard let composition = schedule.composition else { return .succeeded }
        return await launchScheduledAgent(for: schedule, composition: composition, worktree: worktree, project: project)
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
    ) async -> RunScheduleOutcome {
        let discovery = await runScheduleScriptDiscovery(worktree.path, project.host)
        let scripts: [RunScript]
        switch discovery {
        case .scripts(let found):
            scripts = found
        case .failed(let message):
            return .launchFailed("Could not list scripts in \(worktree.branch): \(message)")
        }
        guard let script = scripts.first(where: { $0.key == key }) else {
            return .skipped(reason: "Script \(key) was not found in \(worktree.branch).")
        }
        if runningScriptTab(for: script, in: worktree) != nil
            || runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive == true {
            return .skipped(reason: "\(script.displayName) is already running in \(worktree.branch).")
        }
        let settlement: RunScriptSettlement = await withCheckedContinuation { continuation in
            switch startScriptLaunch(script, in: worktree, presentsLaunchFailure: false) {
            case .started(let runID):
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
            return RunScheduleOutcome(outcome)
        case .launchFailed(let message):
            return .launchFailed(message)
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
