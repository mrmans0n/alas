@_spi(AppHost) import AlasCore
import Foundation
import os

private let runScheduleLogger = Logger(subsystem: "io.nlopez.alas", category: "RunSchedules")

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
        invocation: RunScheduleInvocation = .scheduled
    ) async -> RunScheduleRunReport {
        await core.runSchedule(schedule, invocation: invocation) { await self.runSchedule($0, project: $1, worktree: $2) }
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
        runHistory.hasReport(worktreeID: run.worktreeID, runID: run.runID)
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
            where runHistory.durableReportIDsByWorktreeID[worktreeID]?.isEmpty != false {
            await runHistory.reloadDurableReportIDs(worktreeID: worktreeID)
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
                // Deleting a schedule cancels its targets, which makes
                // creation report that it was interrupted. That is the
                // deletion working, not a failure to announce.
                if Task.isCancelled {
                    return RunScheduleRunReport(
                        outcome: .skipped(reason: "The schedule was removed while its worktree was being created.")
                    )
                }
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
        var agent = await launchScheduledAgent(
            for: schedule, composition: composition, worktree: worktree, project: project
        )
        agent.runs = references
        return agent
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
        // Nothing is announced for a cancelled run. Cancellation here means
        // the schedule was deleted, and every step it interrupts on the way
        // out reports itself as having failed. Guarded centrally so no
        // future call site has to remember.
        guard !Task.isCancelled else { return }
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
        // and every later one would collide with what it left behind: the
        // destination it still occupies, or the branch it kept after the
        // worktree went away.
        return await createWorktreeAtFreeDestination(rendered: rendered, project: project)
    }

    /// Creates a worktree at the first free branch and path for `rendered`, suffixed when the
    /// name is taken. Creations in one project run one at a time from picking the name until the
    /// worktree exists: two overlapping starts (two plugins, or a plugin and a schedule) would
    /// otherwise both probe before either worktree existed and pick the same name.
    func createWorktreeAtFreeDestination(
        rendered: String,
        project: ProjectConfig
    ) async -> Result<Worktree, WorktreeCreationFailure> {
        await host.worktrees.withFreeName(projectID: project.id, rendered: rendered, caller: .app) { prepared in
            await createWorktreeAndWait(
                projectId: project.id,
                base: prepared.request.base,
                branch: prepared.request.branch,
                destination: prepared.request.destination,
                runStartup: true
            )
        }
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
                outcome: .launchFailed("Could not list scripts in \(worktree.title): \(message)")
            )
        }
        guard let script = scripts.first(where: { $0.key == key }) else {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "Script \(key) was not found in \(worktree.title).")
            )
        }
        if runningScriptTab(for: script, in: worktree) != nil
            || runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive == true {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "\(script.displayName) is already running in \(worktree.title).")
            )
        }
        var reference: RunScheduleFiring.RunReference?
        let settlement: RunScriptSettlement = await withCheckedContinuation { continuation in
            switch startScriptLaunch(script, in: worktree, presentsLaunchFailure: false, onSettled: {
                continuation.resume(returning: $0)
            }) {
            case .started(let runID):
                reference = RunScheduleFiring.RunReference(
                    worktreeID: worktree.id,
                    branch: worktree.branch,
                    runID: runID,
                    scriptName: script.displayName
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
        promptID: UUID = UUID()
    ) -> WorktreeLaunchSurface {
        guard ACPLaunchCatalog.spec(for: agentId) != nil else {
            return .terminal(agentId: agentId)
        }
        return .acp(agentId: agentId, preparedPrompt: PreparedWorktreeACPPrompt(
            sessionID: sessionID,
            promptID: promptID,
            text: composition.prompt ?? "",
            sendsAutomatically: composition.sendsPromptAutomatically,
            modelID: composition.modelId
        ))
    }

    private func launchScheduledAgent(
        for schedule: RunSchedule,
        composition: RunScheduleComposition,
        worktree: Worktree,
        project: ProjectConfig
    ) async -> RunScheduleRunReport {
        let agentId = composition.agentId ?? defaultAgentID(projectId: project.id, worktreeRoot: worktree.path)
        guard let agentId else {
            let message = "No agent is configured to launch for \(project.name)."
            reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
            return RunScheduleRunReport(outcome: .launchFailed(message))
        }
        let launchSurface = Self.scheduledLaunchSurface(agentId: agentId, composition: composition)
        // Expected before the launch, because a turn that ends while the
        // launch is still returning must not be missed.
        if case .acp(_, let prepared?) = launchSurface, ScheduledAgentTurns.awaits(prepared.text, sendsAutomatically: prepared.sendsAutomatically) {
            scheduledAgentTurns.expect(prepared.sessionID)
        }
        defer {
            if case .acp(_, let prepared?) = launchSurface {
                scheduledAgentTurns.abandon(prepared.sessionID)
            }
        }
        let tab: Tab?
        do {
            tab = try await launchWorktreeSurface(launchSurface, worktree: worktree, project: project)
        } catch {
            // Deleting a schedule cancels its targets, and that cancellation
            // arrives here as a thrown error. Recording it as a launch
            // failure would leave the worktree in a retryable failed state
            // and raise failure notifications for work deliberately stopped.
            if Task.isCancelled || error is CancellationError {
                return RunScheduleRunReport(
                    outcome: .skipped(reason: "The schedule was removed while its agent was launching.")
                )
            }
            markWorktreeLaunchFailed(
                worktree: worktree,
                error: error,
                launchSurface: launchSurface
            )
            reportScheduleFailure(
                schedule, reason: error.localizedDescription, project: project, worktree: worktree
            )
            runScheduleLogger.error(
                "Scheduled agent launch failed for \(schedule.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return RunScheduleRunReport(outcome: .launchFailed(error.localizedDescription))
        }
        let agentName = agentRegistry.agents.first { $0.id == agentId }?.displayName ?? agentId
        if case .acp(_, let prepared?) = launchSurface {
            return await scheduledChatSessionOutcome(
                prepared, schedule: schedule, worktree: worktree, project: project, agentName: agentName
            )
        }
        inAppNotifications.post(
            "\(schedule.name): launched \(agentName) in \(worktree.title)",
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
        return RunScheduleRunReport(outcome: .succeeded)
    }

    /// What became of a scheduled chat session once its launch returned.
    ///
    /// The launch opens the tab and attaches; an agent that could not start
    /// (missing adapter, no login) leaves its reason on the session, and the
    /// prompt stays queued or in the composer for when the user sorts it out.
    /// That is a launch failure: unlike a terminal, a chat session knows
    /// whether its agent came up.
    ///
    /// A model the agent refused is not: the agent is running, on its own
    /// default, and only the choice was lost. Said in the app so the user
    /// learns why the transcript names a different model.
    ///
    /// A prompt sent automatically is then awaited: the firing stays running
    /// until that turn ends, and its outcome and the agent's final message
    /// become the firing's result and report. A prompt left in the composer
    /// is the user's to send, so launching is all there is to report.
    private func scheduledChatSessionOutcome(
        _ prepared: PreparedWorktreeACPPrompt,
        schedule: RunSchedule,
        worktree: Worktree,
        project: ProjectConfig,
        agentName: String
    ) async -> RunScheduleRunReport {
        // Mirrors the terminal path's cancellation handling: the schedule
        // was removed while the agent was launching, so nothing is wrong —
        // `openPreparedWorktreeACPSession` bailed before enqueueing the
        // prompt or attaching, and the session sitting idle is not a
        // failure worth reporting.
        guard !Task.isCancelled else {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "The schedule was removed while its agent was launching.")
            )
        }
        guard let session = acpManager(forWorktreeId: worktree.id)?.liveSession(for: prepared.sessionID) else {
            let message = "Could not open a chat session for \(agentName) in \(worktree.title)."
            reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
            return RunScheduleRunReport(outcome: .launchFailed(message))
        }
        if let reason = session.lastError {
            let message = "\(agentName) could not start in \(worktree.title): \(reason)"
            reportScheduleFailure(schedule, reason: message, project: project, worktree: worktree)
            return RunScheduleRunReport(outcome: .launchFailed(message))
        }
        inAppNotifications.post(
            "\(schedule.name): launched \(agentName) in \(worktree.title)",
            severity: .success,
            worktreeID: worktree.id
        )
        if let modelID = prepared.modelID, session.currentModel != modelID {
            let modelName = acpModelCatalog.models(for: session.agentId).first { $0.id == modelID }?.name ?? modelID
            inAppNotifications.post(
                "\(schedule.name): \(agentName) did not accept the model \(modelName), so it is using its default.",
                severity: .error,
                worktreeID: worktree.id
            )
        }
        guard ScheduledAgentTurns.awaits(prepared.text, sendsAutomatically: prepared.sendsAutomatically) else {
            return RunScheduleRunReport(outcome: .succeeded)
        }
        let completion = await scheduledAgentTurns.wait(
            for: prepared.sessionID, timeout: ScheduledAgentTurns.turnTimeout
        )
        guard !Task.isCancelled else {
            return RunScheduleRunReport(
                outcome: .skipped(reason: "The schedule was removed while its agent was working.")
            )
        }
        let outcome = RunScheduleOutcome(completion?.result)
        switch completion?.result {
        case .completed:
            inAppNotifications.post(
                "\(schedule.name): \(agentName) finished in \(worktree.title)",
                severity: .success,
                worktreeID: worktree.id
            )
        case .failed(let message):
            reportScheduleFailure(
                schedule, reason: "\(agentName) failed in \(worktree.title): \(message)",
                project: project, worktree: worktree
            )
        case .limited:
            reportScheduleFailure(
                schedule, reason: "\(agentName) hit its usage limit in \(worktree.title).",
                project: project, worktree: worktree
            )
        case .stopped(let reason):
            reportScheduleFailure(
                schedule, reason: "\(agentName) stopped in \(worktree.title): \(reason.summary).",
                project: project, worktree: worktree
            )
        case .cancelled:
            // Cancellation is recorded by the schedule's stopped outcome.
            break
        case nil:
            reportScheduleFailure(
                schedule, reason: "\(agentName) was still working in \(worktree.title) after 4 hours; stopped waiting.",
                project: project, worktree: worktree
            )
        }
        guard completion != nil, let text = await ScheduledAgentTurns.reply(in: session) else {
            return RunScheduleRunReport(outcome: outcome)
        }
        return RunScheduleRunReport(outcome: outcome, agentReports: [RunScheduleFiring.AgentReport(
            worktreeID: worktree.id,
            branch: worktree.branch,
            agentName: agentName,
            text: text
        )])
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
                "\(schedule.name): could not confirm the agent was ready in \(worktree.title), so the prompt was not sent.",
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
                "\(schedule.name): the agent's terminal in \(worktree.title) closed before the prompt could be sent.",
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
                "\(schedule.name): the agent stopped before the prompt could be submitted in \(worktree.title).",
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
