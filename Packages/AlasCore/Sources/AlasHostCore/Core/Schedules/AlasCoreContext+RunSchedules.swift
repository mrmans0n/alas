import Foundation
import os
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasIntegrations
import AlasACP
import AlasAgentKit

private let runScheduleLogger = Logger(subsystem: "io.nlopez.alas", category: "RunSchedules")

extension AlasCoreContext {
    public enum ScheduleTargetResolution {
        case targets([(project: ProjectConfig, worktree: Worktree)])
        /// Nothing to run against; `reason` is shown on the schedule row.
        case unavailable(String)
    }

    public func resolveScheduleTargets(
        _ target: RunScheduleTarget,
        invocation: RunScheduleInvocation = .scheduled
    ) -> ScheduleTargetResolution {
        switch target {
        case .allProjects:
            let candidates = projects.projects.compactMap { project -> (project: ProjectConfig, worktree: Worktree)? in
                guard let main = projects.visibleMainWorktree(projectId: project.id) else { return nil }
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
            guard let project = projects.projects.first(where: { $0.id == id }) else {
                return .unavailable("The project no longer exists.")
            }
            if invocation.honorsProjectPauses, runScheduler.isProjectPaused(id) {
                return .unavailable("\(project.name) is paused.")
            }
            guard let main = projects.visibleMainWorktree(projectId: id) else {
                return .unavailable("\(project.name) has no main worktree.")
            }
            return .targets([(project, main)])
        case let .worktree(projectId, worktreeId):
            guard let project = projects.projects.first(where: { $0.id == projectId }) else {
                return .unavailable("The project no longer exists.")
            }
            if invocation.honorsProjectPauses, runScheduler.isProjectPaused(projectId) {
                return .unavailable("\(project.name) is paused.")
            }
            guard let worktree = projects.worktrees(projectId: projectId).first(where: { $0.id == worktreeId }) else {
                return .unavailable("The worktree no longer exists in \(project.name).")
            }
            return .targets([(project, worktree)])
        }
    }

    /// Runs a schedule once against every target it resolves to, through
    /// `target` per project and worktree.
    public func runSchedule(
        _ schedule: RunSchedule,
        invocation: RunScheduleInvocation,
        target: @escaping @MainActor (RunSchedule, ProjectConfig, Worktree) async -> RunScheduleRunReport
    ) async -> RunScheduleRunReport {
        let targets: [(project: ProjectConfig, worktree: Worktree)]
        switch resolveScheduleTargets(schedule.target, invocation: invocation) {
        case .targets(let resolved):
            // A worktree-creating schedule skips folders, which cannot have one.
            targets = schedule.composition == nil ? resolved : resolved.filter { !$0.project.isFolder }
            guard !targets.isEmpty else {
                return RunScheduleRunReport(outcome: .skipped(reason: Self.folderWorktreeCreationMessage))
            }
        case .unavailable(let reason):
            return RunScheduleRunReport(outcome: .skipped(reason: reason))
        }
        // Start every target before waiting on any of them. Run scripts are
        // allowed to be long-running servers that never exit, so awaiting one
        // target's settlement before launching the next would let the first
        // project starve all the others indefinitely. Each child suspends on
        // its own run's settlement, which lets the next one start.
        let runs = targets.map { resolved in
            Task { @MainActor in
                await target(schedule, resolved.project, resolved.worktree)
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
        // Every target's run is linked, not just the one whose outcome won:
        // a fan-out that failed in one project should still let the user open
        // the reports of the projects that did run.
        return RunScheduleRunReport(
            outcome: .combined(reports.map(\.outcome)),
            runs: reports.flatMap(\.runs),
            agentReports: reports.flatMap(\.agentReports)
        )
    }
}

// MARK: - Headless runner

extension AlasCoreContext {
    /// Fires schedules without the app: scripts run as core runs, agents as
    /// chat sessions, and whatever needs someone at the screen is refused.
    public func installDefaultRunScheduleRunner() {
        runScheduler.runner = { [weak self] schedule, invocation in
            guard let self else { return RunScheduleRunReport(outcome: .launchFailed("The host is stopping.")) }
            return await self.runSchedule(schedule, invocation: invocation) {
                await self.runHeadlessScheduleTarget($0, project: $1, worktree: $2)
            }
        }
    }

    /// Mirrors the app's `runSchedule(_:project:worktree:)`, with in-app
    /// notices as log lines.
    func runHeadlessScheduleTarget(
        _ schedule: RunSchedule,
        project: ProjectConfig,
        worktree originWorktree: Worktree
    ) async -> RunScheduleRunReport {
        func refuse(_ reason: String, in worktree: Worktree) -> RunScheduleRunReport {
            reportScheduleFailure(schedule, reason: reason, project: project, worktree: worktree)
            return RunScheduleRunReport(outcome: .launchFailed(reason))
        }
        /// Why the agent (resolved at `root` when it is the project default)
        /// cannot launch here; nil when it can.
        func agentRefusal(_ composition: RunScheduleComposition, at root: URL) -> (agentID: String?, refusal: String?) {
            guard let agentID = composition.agentId
                ?? SessionsAPI(core: self).defaultAgent(projectID: project.id, worktreeRoot: root)
            else { return (nil, "No agent is configured to launch for \(project.name).") }
            return (agentID, RunSchedulePresentation.headlessRefusal(
                composition: composition,
                projectName: project.name,
                projectHost: project.host,
                agentName: environment.agent(id: agentID)?.displayName ?? agentID,
                agentSpeaksACP: ACPLaunchCatalog.spec(for: agentID) != nil
            ))
        }
        // The project's host first: an SSH project's default agent may not
        // resolve at all, which would otherwise read as no agent configured.
        if let refusal = RunSchedulePresentation.headlessRefusal(
            composition: nil, projectName: project.name, projectHost: project.host, agentName: nil, agentSpeaksACP: false
        ) {
            return refuse(refusal, in: originWorktree)
        }
        var agentID: String?
        if let composition = schedule.composition {
            let resolved = agentRefusal(composition, at: originWorktree.path)
            if let refusal = resolved.refusal { return refuse(refusal, in: originWorktree) }
            agentID = resolved.agentID
        }

        var worktree = originWorktree
        if let composition = schedule.composition {
            switch await createScheduledWorktree(for: schedule, composition: composition, project: project) {
            case .success(let created):
                worktree = created
            case .failure(let failure):
                if Task.isCancelled {
                    return RunScheduleRunReport(
                        outcome: .skipped(reason: "The schedule was removed while its worktree was being created.")
                    )
                }
                return refuse(failure.message, in: originWorktree)
            }
            // The app resolves the project default in the new worktree, whose
            // repository config can name another agent: checked again there,
            // before its script runs.
            if composition.agentId == nil {
                let resolved = agentRefusal(composition, at: worktree.path)
                if let refusal = resolved.refusal { return refuse(refusal, in: worktree) }
                agentID = resolved.agentID
            }
        }

        var references: [RunScheduleFiring.RunReference] = []
        if let scriptKey = schedule.scriptKey {
            let script = await runScheduledScript(key: scriptKey, in: worktree, project: project)
            references = script.runs
            guard case .succeeded = script.outcome else {
                switch script.outcome {
                case .skipped:
                    break
                case .launchFailed(let message):
                    reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
                default:
                    if schedule.composition != nil {
                        runScheduleLogger.notice("\(schedule.name, privacy: .public): script did not succeed, agent not launched.")
                    }
                }
                return RunScheduleRunReport(outcome: script.outcome, runs: references)
            }
        }

        guard let composition = schedule.composition, let agentID else {
            return RunScheduleRunReport(outcome: .succeeded, runs: references)
        }
        var agent = await runScheduledChatSession(
            schedule, composition: composition, agentID: agentID, worktree: worktree, project: project
        )
        agent.runs = references
        return agent
    }

    /// Announces a failure nothing else reports; nothing for a removed
    /// schedule, whose interrupted steps all report themselves as failing.
    private func reportScheduleFailure(_ schedule: RunSchedule, reason: String, project: ProjectConfig, worktree: Worktree) {
        guard !Task.isCancelled else { return }
        runScheduleLogger.error("\(schedule.name, privacy: .public): \(reason, privacy: .public)")
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
        let rendered = RunSchedulePlanner.renderBranch(template: composition.branchTemplate, name: schedule.name, now: Date())
        if case .invalid(let message) = GitNameValidator.validateBranchName(rendered) {
            return .failure(.init(message: "Invalid branch name \"\(rendered)\": \(message)"))
        }
        let worktrees = WorktreesAPI(core: self)
        return await worktrees.withFreeName(projectID: project.id, rendered: rendered, caller: .cli) { prepared in
            do {
                return .success(try await worktrees.create(prepared.request, caller: .cli))
            } catch {
                return .failure(.init(message: error.localizedDescription))
            }
        }
    }

    private func runScheduledScript(key: String, in worktree: Worktree, project: ProjectConfig) async -> RunScheduleRunReport {
        let scripts: [RunScript]
        switch await RunScriptStore.discoverScripts(worktreeRoot: worktree.path, remoteHost: project.host) {
        case .scripts(let found):
            scripts = found
        case .failed(let message):
            return RunScheduleRunReport(outcome: .launchFailed("Could not list scripts in \(worktree.title): \(message)"))
        }
        guard let script = scripts.first(where: { $0.key == key }) else {
            return RunScheduleRunReport(outcome: .skipped(reason: "Script \(key) was not found in \(worktree.title)."))
        }
        if runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive == true {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "\(script.displayName) is already running in \(worktree.title).")
            )
        }
        var reference: RunScheduleFiring.RunReference?
        let settlement: RunScriptSettlement = await withCheckedContinuation { continuation in
            // Started as a peer starts a run: nobody is at this host to show
            // a console to or ask about a repository hook.
            switch startRun(
                script, in: worktree, isHidden: script.console == .hidden, activatesConsole: false,
                promptsForRepoHooks: false, onSettled: { continuation.resume(returning: $0) }
            ) {
            case .started(let runID):
                reference = RunScheduleFiring.RunReference(
                    worktreeID: worktree.id, branch: worktree.branch, runID: runID, scriptName: script.displayName
                )
            case .alreadyStarting:
                continuation.resume(returning: .launchFailed("\(script.displayName) is already starting in \(worktree.title)."))
            case .projectUnavailable:
                continuation.resume(returning: .launchFailed("The project is no longer available."))
            case let .refused(_, message):
                continuation.resume(returning: .launchFailed(message))
            }
        }
        switch settlement {
        case .finished(let outcome):
            return RunScheduleRunReport(outcome: RunScheduleOutcome(outcome), runs: reference.map { [$0] } ?? [])
        case .launchFailed(let message):
            return RunScheduleRunReport(outcome: .launchFailed(message))
        }
    }

    /// Starts the schedule's chat session as the app's prepared launch does,
    /// model included, then reports as the app's `scheduledChatSessionOutcome`.
    private func runScheduledChatSession(
        _ schedule: RunSchedule,
        composition: RunScheduleComposition,
        agentID: String,
        worktree: Worktree,
        project: ProjectConfig
    ) async -> RunScheduleRunReport {
        let prepared = PreparedWorktreeACPPrompt(
            sessionID: UUID().uuidString,
            promptID: UUID(),
            text: composition.prompt ?? "",
            sendsAutomatically: composition.sendsPromptAutomatically,
            modelID: composition.modelId
        )
        let awaitsTurn = ScheduledAgentTurns.awaits(prepared.text, sendsAutomatically: prepared.sendsAutomatically)
        // Expected before the launch, so a turn ending while it returns is kept.
        if awaitsTurn { scheduledAgentTurns.expect(prepared.sessionID) }
        defer { scheduledAgentTurns.abandon(prepared.sessionID) }
        await SessionsAPI(core: self).startPrepared(prepared, agentID: agentID, in: worktree, caller: .cli)
        let agentName = environment.agent(id: agentID)?.displayName ?? agentID
        guard !Task.isCancelled else {
            return RunScheduleRunReport(outcome: .skipped(reason: "The schedule was removed while its agent was launching."))
        }
        guard let session = orchestrationManager(for: worktree)?.liveSession(for: prepared.sessionID) else {
            let message = "Could not open a chat session for \(agentName) in \(worktree.title)."
            reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
            return RunScheduleRunReport(outcome: .launchFailed(message))
        }
        if let reason = session.lastError {
            let message = "\(agentName) could not start in \(worktree.title): \(reason)"
            reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
            return RunScheduleRunReport(outcome: .launchFailed(message))
        }
        runScheduleLogger.notice("\(schedule.name, privacy: .public): launched \(agentName, privacy: .public) in \(worktree.title, privacy: .public)")
        if let modelID = prepared.modelID, session.currentModel != modelID {
            runScheduleLogger.notice(
                "\(schedule.name, privacy: .public): \(agentName, privacy: .public) did not accept the model \(modelID, privacy: .public), so it is using its default."
            )
        }
        guard awaitsTurn else { return RunScheduleRunReport(outcome: .succeeded) }
        let completion = await scheduledAgentTurns.wait(for: prepared.sessionID, timeout: ScheduledAgentTurns.turnTimeout)
        guard !Task.isCancelled else {
            return RunScheduleRunReport(outcome: .skipped(reason: "The schedule was removed while its agent was working."))
        }
        switch completion?.result {
        case .completed:
            runScheduleLogger.notice("\(schedule.name, privacy: .public): \(agentName, privacy: .public) finished in \(worktree.title, privacy: .public)")
        case .failed(let message):
            reportScheduleFailure(
                schedule, reason: "\(agentName) failed in \(worktree.title): \(message)", project: project, worktree: worktree
            )
        case .limited:
            reportScheduleFailure(
                schedule, reason: "\(agentName) hit its usage limit in \(worktree.title).", project: project, worktree: worktree
            )
        case .cancelled:
            break
        case nil:
            reportScheduleFailure(
                schedule, reason: "\(agentName) was still working in \(worktree.title) after 4 hours; stopped waiting.",
                project: project, worktree: worktree
            )
        }
        let outcome = RunScheduleOutcome(completion?.result)
        guard completion != nil, let text = await ScheduledAgentTurns.reply(in: session) else {
            return RunScheduleRunReport(outcome: outcome)
        }
        return RunScheduleRunReport(outcome: outcome, agentReports: [RunScheduleFiring.AgentReport(
            worktreeID: worktree.id, branch: worktree.branch, agentName: agentName, text: text
        )])
    }
}
