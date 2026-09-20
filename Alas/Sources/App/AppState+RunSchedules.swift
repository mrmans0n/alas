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
        runScheduler.runner = { [weak self] schedule in
            guard let self else { return .launchFailed("Alas is shutting down.") }
            return await self.runSchedule(schedule)
        }
    }

    // MARK: - Execution

    /// Runs a schedule once. Every step reuses the manual path: worktree
    /// creation goes through `createWorktreeAndWait`, the script through the
    /// same launch used by the Run tab, and the agent through the worktree
    /// launch surface. The returned outcome is what the schedule row shows.
    func runSchedule(_ schedule: RunSchedule) async -> RunScheduleOutcome {
        let targets: [(project: ProjectConfig, worktree: Worktree)]
        switch resolveScheduleTargets(schedule.target) {
        case .targets(let resolved):
            targets = resolved
        case .unavailable(let reason):
            return .skipped(reason: reason)
        }
        var outcomes: [RunScheduleOutcome] = []
        for target in targets {
            let outcome = await runSchedule(schedule, project: target.project, worktree: target.worktree)
            outcomes.append(outcome)
        }
        return RunScheduleOutcome.combined(outcomes)
    }

    enum ScheduleTargetResolution {
        case targets([(project: ProjectConfig, worktree: Worktree)])
        /// Nothing to run against; `reason` is shown on the schedule row.
        case unavailable(String)
    }

    func resolveScheduleTargets(_ target: RunScheduleTarget) -> ScheduleTargetResolution {
        switch target {
        case .allProjects:
            let resolved = projects.compactMap { project -> (project: ProjectConfig, worktree: Worktree)? in
                guard let main = projectsManager.visibleMainWorktree(projectId: project.id) else { return nil }
                return (project, main)
            }
            guard !resolved.isEmpty else { return .unavailable("No project has a main worktree to run in.") }
            return .targets(resolved)
        case .project(let id):
            guard let project = projects.first(where: { $0.id == id }) else {
                return .unavailable("The project no longer exists.")
            }
            guard let main = projectsManager.visibleMainWorktree(projectId: id) else {
                return .unavailable("\(project.name) has no main worktree.")
            }
            return .targets([(project, main)])
        case let .worktree(projectId, worktreeId):
            guard let project = projects.first(where: { $0.id == projectId }) else {
                return .unavailable("The project no longer exists.")
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
                inAppNotifications.post(
                    "\(schedule.name): \(failure.message)",
                    severity: .error,
                    worktreeID: originWorktree.id
                )
                return .launchFailed(failure.message)
            }
        }

        if let scriptKey = schedule.scriptKey {
            let scriptOutcome = await runScheduledScript(key: scriptKey, in: worktree, project: project)
            guard case .succeeded = scriptOutcome else {
                if case .skipped = scriptOutcome {
                    // Nothing was launched, so there is nothing to compose on.
                } else if schedule.composition != nil {
                    inAppNotifications.post(
                        "\(schedule.name): script did not succeed, agent not launched.",
                        severity: .error,
                        worktreeID: worktree.id
                    )
                }
                return scriptOutcome
            }
        }

        guard let composition = schedule.composition else { return .succeeded }
        return await launchScheduledAgent(for: schedule, composition: composition, worktree: worktree, project: project)
    }

    private func createScheduledWorktree(
        for schedule: RunSchedule,
        composition: RunScheduleComposition,
        project: ProjectConfig
    ) async -> Result<Worktree, WorktreeCreationFailure> {
        let branch = RunSchedulePlanner.renderBranch(
            template: composition.branchTemplate,
            name: schedule.name,
            now: Date()
        )
        switch GitNameValidator.validateBranchName(branch) {
        case .valid:
            break
        case .invalid(let message):
            return .failure(.init(message: "Invalid branch name \"\(branch)\": \(message)"))
        }
        let destination = WorktreePathTemplateRenderer.render(
            template: config.worktrees.pathTemplate,
            worktreeRoot: config.worktrees.rootPath,
            repoName: project.name,
            branch: branch
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            return .failure(.init(message: "A worktree already exists at \(destination.path)."))
        }
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
            switch startScriptLaunch(script, in: worktree) {
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
            inAppNotifications.post("\(schedule.name): \(message)", severity: .error, worktreeID: worktree.id)
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
            inAppNotifications.post(
                "\(schedule.name): \(error.localizedDescription)",
                severity: .error,
                worktreeID: worktree.id
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
