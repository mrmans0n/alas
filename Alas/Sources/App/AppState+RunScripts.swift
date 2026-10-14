@_spi(AppHost) import AlasCore
import Foundation

/// What `startScriptLaunch` did with a request.
typealias RunScriptLaunchStart = RunStart

extension AppState {
    // MARK: - Launch

    func scriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        scriptTab(scriptKey: script.key, worktreeID: worktree.id)
    }

    func scriptTab(scriptKey: String, worktreeID: String) -> Tab? {
        tabs.tabs(forWorktree: worktreeID).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.runScriptKey == scriptKey
        }
    }

    /// The script's tab *with a live shell behind it*. Used to decide whether
    /// there is a terminal worth jumping to — never to decide whether the
    /// command itself is still running; `runRecords` owns that.
    func runningScriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        runningScriptTab(scriptKey: script.key, worktreeID: worktree.id)
    }

    func runningScriptTab(scriptKey: String, worktreeID: String) -> Tab? {
        tabs.tabs(forWorktree: worktreeID).first { tab in
            guard case .terminal(let state) = tab,
                  state.runScriptKey == scriptKey,
                  let runScriptLeafId = state.runScriptLeafId,
                  let leaf = state.root.find(leafId: runScriptLeafId)?.leaf
            else { return false }
            return terminal.registry.session(for: leaf.sessionId) != nil
        }
    }

    /// Enter/click semantics: focus the script's open tab when it exists,
    /// otherwise launch a new one. One tab per (script, worktree).
    /// `console` overrides the script's `alas-console` default for this run.
    func runOrFocusScript(_ script: RunScript, in worktree: Worktree, console: RunScriptConsole? = nil) {
        if let existing = scriptTab(for: script, in: worktree), existing.isHiddenRunTab,
           runRecords.record(worktreeID: worktree.id, scriptKey: script.key)?.status.isActive != true {
            // An idle background console was never shown; rerun instead of
            // popping it open.
            restartScript(script, in: worktree, console: console)
            return
        }
        if let existing = runningScriptTab(for: script, in: worktree) {
            // Activation reveals a hidden tab: clicking a running script means "show me".
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
            return
        }
        launchScript(script, in: worktree, console: console)
    }

    /// How the script's current run is shown: a launch still starting keeps its
    /// mode, otherwise the tab's visibility. Nil when there is nothing to repeat.
    func currentRunConsole(scriptKey: String, worktreeID: String) -> RunScriptConsole? {
        if let isHidden = core.startingRunIsHidden(scriptKey: scriptKey, worktreeID: worktreeID) { return isHidden ? .hidden : .shown }
        guard let tab = scriptTab(scriptKey: scriptKey, worktreeID: worktreeID) else { return nil }
        return tab.isHiddenRunTab ? .hidden : .shown
    }

    /// Restart repeats the run the way it was shown: without an explicit
    /// `console`, the current run's visibility wins over the script default.
    @discardableResult
    func restartScript(
        _ script: RunScript,
        in worktree: Worktree,
        presentsLaunchFailure: Bool = true,
        console: RunScriptConsole? = nil
    ) -> RunScriptLaunchStart {
        let resolvedConsole = console ?? currentRunConsole(scriptKey: script.key, worktreeID: worktree.id)
        let result = core.restartRun(
            script,
            in: worktree,
            isHidden: (resolvedConsole ?? script.console) == .hidden,
            onSettled: launchFailureAlert(presents: presentsLaunchFailure)
        )
        if presentsLaunchFailure, case let .refused(title, message) = result {
            showFileActionError(title: title, message: message)
        }
        return result
    }

    /// Restart from a run record, which only knows the script key. Resolves
    /// the script through the same host-aware discovery the Run tab uses, so a
    /// remote worktree's repo scripts are found.
    func restartScript(scriptKey: String, in worktree: Worktree) {
        let before = runRecords.record(worktreeID: worktree.id, scriptKey: scriptKey)
        let host = webPreviewRemoteHost(for: worktree)
        Task { @MainActor in
            let result = await RunScriptStore.discoverScripts(worktreeRoot: worktree.path, remoteHost: host)
            let now = runRecords.record(worktreeID: worktree.id, scriptKey: scriptKey)
            guard Self.restartStillWanted(before: before, now: now) else { return }
            switch result {
            case .scripts(let found):
                guard let script = found.first(where: { $0.key == scriptKey }) else {
                    showFileActionError(title: "Run Script Failed", message: "This script no longer exists.")
                    return
                }
                restartScript(script, in: worktree)
            case .failed(let message):
                showFileActionError(title: "Run Script Failed", message: message)
            }
        }
    }

    /// Whether a restart requested before async discovery should still run.
    /// Another launch taking the slot, or the user stopping the run while
    /// discovery was in flight, cancels it: the later action wins.
    nonisolated static func restartStillWanted(before: RunRecord?, now: RunRecord?) -> Bool {
        guard now?.id == before?.id else { return false }
        let stoppedMeanwhile = now?.status == .finished(.stopped) && before?.status != .finished(.stopped)
        return !stoppedMeanwhile
    }

    func stopScript(_ script: RunScript, in worktree: Worktree) {
        stopScript(scriptKey: script.key, in: worktree)
    }

    /// Stop an in-flight run by closing the terminal that hosts it.
    func stopScript(scriptKey: String, in worktree: Worktree) {
        core.stopRun(scriptKey: scriptKey, in: worktree)
    }

    func focusScriptTerminal(_ script: RunScript, in worktree: Worktree) {
        focusScriptTerminal(scriptKey: script.key, in: worktree)
    }

    /// Reveal the terminal a run is (or was) hosted in. Scoped to `worktree`
    /// so a same-named script in another worktree is never focused.
    /// Activation also un-hides a background run's tab.
    func focusScriptTerminal(scriptKey: String, in worktree: Worktree) {
        guard let existing = runningScriptTab(scriptKey: scriptKey, worktreeID: worktree.id) else { return }
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
    }

    /// Re-check active records whose terminal has gone away. Called when the
    /// Run tab appears, so reconnecting to a worktree settles uncertain runs
    /// instead of leaving them stuck on "Running".
    func reconcileRunRecords(worktreeID: String) {
        core.reconcileRuns(worktreeID: worktreeID)
    }

    func runExecutionTarget(for script: RunScript, in worktree: Worktree) -> RunExecutionTarget {
        core.runExecutionTarget(for: script, in: worktree)
    }

    func webPreviewRemoteHost(for worktree: Worktree) -> String? {
        projects.first(where: { $0.id == worktree.projectId })?.host
            ?? RemoteHostRegistry.shared.host(forPath: worktree.path.path)
    }

    func openWebPreview(in worktree: Worktree, url: URL? = nil) {
        let tab = tabs.openWebPreview(worktreeId: worktree.id, url: url, remoteHost: webPreviewRemoteHost(for: worktree))
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
    }

    /// Opens a run's declared endpoint. A remote run whose URL points at
    /// loopback is refused rather than silently opening whatever serves that
    /// port on this Mac.
    func openRunEndpoint(_ script: RunScript, in worktree: Worktree) {
        guard let endpoint = script.endpoint else { return }
        let currentRecord = runRecords.record(worktreeID: worktree.id, scriptKey: script.key)
        let target: RunExecutionTarget
        if let currentRecord, currentRecord.status.isActive {
            target = currentRecord.target
        } else {
            target = runExecutionTarget(for: script, in: worktree)
        }
        switch RunEndpointPolicy.action(for: endpoint, target: target) {
        case .open(let url):
            let tab = tabs.openWebPreview(worktreeId: worktree.id, url: url, remoteHost: target.host)
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: tab.id)
        case let .blockedRemoteLoopback(host, url):
            showFileActionError(
                title: "Can't Open Endpoint",
                message: "\(script.displayName) runs on \(host), but \(url.absoluteString) points at this Mac. Set `# alas-url:` to a URL reachable from here, or forward the port over SSH."
            )
        }
    }

    /// `presentsLaunchFailure` false hands a refusal back to the caller instead of alerting the user.
    @discardableResult
    func launchScript(
        _ script: RunScript,
        in worktree: Worktree,
        presentsLaunchFailure: Bool = true,
        console: RunScriptConsole? = nil
    ) -> RunScriptLaunchStart {
        let result = startScriptLaunch(script, in: worktree, presentsLaunchFailure: presentsLaunchFailure, console: console)
        if presentsLaunchFailure, case let .refused(title, message) = result {
            showFileActionError(title: title, message: message)
        }
        return result
    }

    /// Claims a run slot and starts the terminal launch, without presenting
    /// anything itself. `launchScript` adds the alert for interactive
    /// callers; the scheduler records the refusal as the run's outcome
    /// instead.
    ///
    /// `presentsLaunchFailure` also covers the *asynchronous* failure that
    /// surfaces once the terminal actually fails to open — an unreachable SSH
    /// host, say. A timer-started run must never put a modal alert in front
    /// of whatever the user is doing; its settlement carries the message to
    /// the schedule row instead.
    func startScriptLaunch(
        _ script: RunScript,
        in worktree: Worktree,
        presentsLaunchFailure: Bool = true,
        console: RunScriptConsole? = nil,
        onSettled: ((RunScriptSettlement) -> Void)? = nil
    ) -> RunScriptLaunchStart {
        let alert = launchFailureAlert(presents: presentsLaunchFailure)
        return core.startRun(
            script,
            in: worktree,
            isHidden: (console ?? script.console) == .hidden,
            onSettled: alert == nil && onSettled == nil ? nil : { settlement in
                alert?(settlement)
                onSettled?(settlement)
            }
        )
    }

    /// Alerts the user when a launch fails after it was claimed, such as an
    /// unreachable SSH host. Nil for runs nobody is watching, like scheduled ones.
    private func launchFailureAlert(presents: Bool) -> ((RunScriptSettlement) -> Void)? {
        guard presents else { return nil }
        return { [weak self] settlement in
            if case .launchFailed(let message) = settlement {
                self?.showFileActionError(title: "Run Script Failed", message: message)
            }
        }
    }

    // MARK: - Settlement

    func runScriptFailures(in worktreeID: String) -> [RunScriptFailure] {
        runScriptFailureQueue.failures(for: worktreeID)
    }

    func dismissRunScriptFailure(id: String, worktreeID: String) {
        if let failure = runScriptFailureQueue.failures(for: worktreeID).first(where: { $0.id == id }),
           let worktree = attentionWorktrees.first(where: { $0.worktree.id == worktreeID })?.worktree,
           let context = attentionContext(for: worktree) {
            let keys = [
                AttentionProducer.scriptSourceKey(scriptKey: failure.scriptKey, owner: context.owner),
                AttentionSourceKey(rawValue: "script:\(failure.runID):failure")
            ]
            for key in keys where attentionStore.document.observations[key]?.fingerprint == id {
                observeAttention(.inactive(sourceKey: key))
            }
        }
        for event in attentionStore.events where event.kind == .runScriptFailure
            && event.jumpTarget == .runScriptFailure(failureID: id)
            && attentionWorktree(for: event.owner)?.id == worktreeID {
            guard let current = attentionStore.document.observations[event.sourceKey],
                  current.isActive, current.eventID == event.id else { continue }
            observeAttention(.inactive(sourceKey: event.sourceKey))
        }
        runScriptFailureQueue.dismiss(id: id, worktreeID: worktreeID)
        runFailureBriefs.retain(runIDs: runScriptFailureQueue.runIDs)
    }

    func setRunFailureBriefsEnabled(_ enabled: Bool) {
        let previous = config.runFailureBriefsEnabled
        config.runFailureBriefsEnabled = enabled
        if saveConfig() {
            onDeviceAIHelperSettingsError = nil
        } else {
            if enabled { config.runFailureBriefsEnabled = previous }
            onDeviceAIHelperSettingsError =
                "Could not save helper settings. Changes apply only to this session. Retry before quitting."
        }
        if !enabled { runFailureBriefs.invalidateAll() }
    }

    private func startRunFailureBrief(for failure: RunScriptFailure) {
        runFailureBriefs.retain(runIDs: runScriptFailureQueue.runIDs)
        guard config.runFailureBriefsEnabled else { return }
        let runID = failure.runID
        runFailureBriefs.start(
            failure,
            loadOutput: { [weak self] in await self?.persistedRunOutput(runID: runID) },
            resolveGenerator: { [weak self] in
                guard let self else { return nil }
                if !LocalTextAppleIntelligence.isAvailable {
                    // MLX is the only route left, so wait for it; Apple never needs this.
                    await self.waitForLocalTextReadiness()
                }
                return self.makeRunFailureBriefGenerator()
            }
        )
    }

    private func persistedRunOutput(runID: String) async -> RunHistoryOutput? {
        await runHistory.flush(runID: runID)
        return try? await runHistoryStore?.entry(id: runID)?.output
    }

    private func retireRunScriptAttention(scriptKey: String, worktree: Worktree, at date: Date) {
        if let context = attentionContext(for: worktree) {
            observeAttention(.inactive(sourceKey: AttentionProducer.scriptSourceKey(
                scriptKey: scriptKey, owner: context.owner
            )), at: date)
        }
        // Legacy run-keyed occurrences can only be matched while their script metadata survives.
        for failure in runScriptFailureQueue.failures(for: worktree.id) where failure.scriptKey == scriptKey {
            observeAttention(.inactive(sourceKey: .init(rawValue: "script:\(failure.runID):failure")), at: date)
            runScriptFailureQueue.dismiss(id: failure.id, worktreeID: worktree.id)
        }
        runFailureBriefs.retain(runIDs: runScriptFailureQueue.runIDs)
    }

    func openRunReport(worktreeID: String, runID: String) {
        let tab = tabs.openOrFocusRunReport(worktreeId: worktreeID, runID: runID)
        activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
        acknowledgeAttentionSurface(worktreeID: worktreeID, target: .runScriptFailure(failureID: runID))
    }

    func openTransientRunReport(_ entry: RunHistoryEntry) {
        runHistory.addTransientReport(entry)
        let tab = tabs.openOrFocusRunReport(worktreeId: entry.worktreeID, runID: entry.id, isTransient: true)
        activateWorktreeCenterTab(worktreeId: entry.worktreeID, tabId: tab.id)
        acknowledgeAttentionSurface(worktreeID: entry.worktreeID, target: .runScriptFailure(failureID: entry.id))
    }

    func clearRunHistory(worktreeID: String) {
        let cutoff = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await runHistory.clear(worktreeID: worktreeID, finishedOnOrBefore: cutoff)
            } catch {
                return
            }
            if runHistoryStore != nil {
                runRecords.purgeFinished(worktreeID: worktreeID, finishedOnOrBefore: cutoff)
            }
            tabs.closeRunReports(worktreeId: worktreeID)
        }
    }

    func waitForRunScriptCompletionTasksForTesting() async {
        let tasks = core.runObservations.values.map(\.task)
        for task in tasks {
            await task.value
        }
    }

    var runScriptCompletionTaskCountForTesting: Int {
        core.runObservations.count
    }

    func flushRunHistoryPersistence(worktreeID: String? = nil) async {
        await runHistory.flush(worktreeID: worktreeID)
    }

    /// Reacts to an observed run finishing: notifications, attention and the
    /// failure queue.
    fileprivate func runScriptFinished(
        _ record: RunRecord,
        completion: RunScriptCompletion,
        script: RunScript,
        worktree: Worktree,
        sessionID: String
    ) {
        let observedAt = record.finishedAt ?? Date()
        harness.notifications.notifyRunScriptFinished(
            scriptName: script.displayName,
            exitCode: completion.exitCode,
            projectId: worktree.projectId,
            worktreeId: worktree.id,
            sessionId: sessionID,
            runID: record.id
        )
        retireRunScriptAttention(scriptKey: script.key, worktree: worktree, at: observedAt)
        guard let failureID = record.failureID else {
            inAppNotifications.post(
                "\(script.displayName) succeeded",
                severity: .success,
                worktreeID: worktree.id
            )
            return
        }
        let failure = RunScriptFailure(
            id: failureID,
            runID: record.id,
            scriptKey: script.key,
            scriptName: script.displayName,
            worktreeID: worktree.id,
            branch: worktree.branch,
            exitCode: completion.exitCode,
            completedAt: observedAt
        )
        runScriptFailureQueue.append(failure)
        startRunFailureBrief(for: failure)
        if let context = attentionContext(for: worktree) {
            for observation in AttentionProducer.script(
                failure: failure, owner: context.owner, display: context.display
            ) {
                observeAttention(observation, at: failure.completedAt)
            }
        }
    }

    fileprivate func runScriptSessionForegroundPidIsMissing(sessionID: String) -> Bool {
        terminal.registry.session(for: sessionID)?.surface.foregroundPid == nil
            && harness.detector.foregroundPid(sessionId: sessionID) == nil
    }

    @discardableResult
    func cleanupRunScriptState(
        worktreeID: String,
        purgeFailures: Bool = true,
        purgeHistory: Bool = true
    ) -> Task<Void, Never>? {
        guard purgeFailures else {
            core.abandonRuns(worktreeID: worktreeID)
            return nil
        }
        // The worktree itself is going away, so its run history goes with
        // it rather than leaking into a future worktree that reuses the id.
        for event in attentionStore.events where event.kind == .runScriptFailure
            && attentionWorktree(for: event.owner)?.id == worktreeID {
            observeAttention(.inactive(sourceKey: event.sourceKey))
        }
        if let worktree = attentionWorktrees.first(where: { $0.worktree.id == worktreeID })?.worktree,
           let context = attentionContext(for: worktree) {
            let prefix = "script:\(context.owner.storageKey):"
            for key in attentionStore.document.observations.keys where key.rawValue.hasPrefix(prefix) {
                observeAttention(.inactive(sourceKey: key))
            }
        }
        runScriptFailureQueue.purge(worktreeID: worktreeID)
        runFailureBriefs.retain(runIDs: runScriptFailureQueue.runIDs)
        tabs.closeRunReports(worktreeId: worktreeID)
        return core.forgetRuns(worktreeID: worktreeID, deletingHistory: purgeHistory)
    }

    func cancelPendingRunScriptLaunches(worktreeID: String? = nil) {
        core.cancelStartingRuns(worktreeID: worktreeID)
    }

    func cancelAllRunScriptCompletionTasks() {
        core.abandonAllRuns()
    }

    // MARK: - Edit

    func editScript(_ script: RunScript, in worktree: Worktree) {
        switch script.scope {
        case .repo:
            openFile(
                relativePath: "\(RunScriptStore.repoScriptsRelativeDir)/\(script.fileName)",
                worktreeId: worktree.id
            )
        case .global:
            _ = tabs.openExternalEditor(
                worktreeId: worktree.id,
                absoluteURL: script.fileURL,
                revealLine: nil,
                revealCharacter: nil,
                editable: true
            )
        }
    }

    // MARK: - Create

    func newRunScript(scope: RunScriptScope, in worktree: Worktree) {
        if scope == .repo, worktree.path.isRemoteAlasPath {
            showFileActionError(
                title: "New Script Failed",
                message: "Run scripts are not supported on remote worktrees yet."
            )
            return
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            showFileActionError(
                title: "New Script Failed",
                message: "The originating project is no longer available."
            )
            return
        }
        pendingRunScriptCreation = RunScriptCreationPresentation(
            scope: scope,
            projectId: project.id,
            worktreeId: worktree.id,
            repositoryName: project.name,
            detectedStacks: scope == .repo ? RunScriptStackDetector.detect(worktreeRoot: worktree.path) : []
        )
    }

    /// Writes every selected template script and opens the first one written.
    /// Existing files are skipped, so this is safe to re-run on a repo that
    /// already has some of the scripts.
    func createPendingRunScripts(
        stack: RunScriptStack,
        actions: [RunScriptStackAction],
        globalDir: URL = Paths.runScriptsGlobalDir
    ) throws {
        guard let presentation = pendingRunScriptCreation,
              let worktree = worktree(withId: presentation.worktreeId),
              worktree.projectId == presentation.projectId
        else {
            throw RunScriptCreationError.worktreeUnavailable
        }
        let result = try RunScriptCreator.createBundle(
            scope: presentation.scope,
            stack: stack,
            actions: actions,
            worktreeRoot: worktree.path,
            globalDir: globalDir
        )
        if let first = result.created.first {
            openCreatedRunScript(at: first, scope: presentation.scope, in: worktree)
        }
        pendingRunScriptCreation = nil
        runScriptCatalogGeneration += 1
    }

    private func openCreatedRunScript(at url: URL, scope: RunScriptScope, in worktree: Worktree) {
        switch scope {
        case .repo:
            openFile(
                relativePath: "\(RunScriptStore.repoScriptsRelativeDir)/\(url.lastPathComponent)",
                worktreeId: worktree.id
            )
        case .global:
            _ = tabs.openExternalEditor(
                worktreeId: worktree.id,
                absoluteURL: url,
                revealLine: nil,
                revealCharacter: nil,
                editable: true
            )
        }
    }

    func createPendingRunScript(
        name: String,
        onExit: RunScriptOnExit,
        globalDir: URL = Paths.runScriptsGlobalDir,
        writingHelpRequest: String? = nil
    ) throws {
        guard let presentation = pendingRunScriptCreation,
              let worktree = worktree(withId: presentation.worktreeId),
              worktree.projectId == presentation.projectId
        else {
            throw RunScriptCreationError.worktreeUnavailable
        }

        if let writingHelpRequest {
            _ = try runScriptWritingHelpAgent(in: worktree)
            guard !writingHelpRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RunScriptWritingHelpError.emptyRequest
            }
        }

        let url = try RunScriptCreator.create(
            scope: presentation.scope,
            name: name,
            onExit: onExit,
            worktreeRoot: worktree.path,
            globalDir: globalDir
        )

        openCreatedRunScript(at: url, scope: presentation.scope, in: worktree)
        pendingRunScriptCreation = nil
        runScriptCatalogGeneration += 1
        if let writingHelpRequest {
            do {
                try startRunScriptWritingHelp(
                    scope: presentation.scope, scriptURL: url, in: worktree, request: writingHelpRequest
                )
            } catch {
                showFileActionError(title: "Writing Help Unavailable", message: error.localizedDescription)
            }
        }
    }

    func cancelPendingRunScriptCreation() {
        pendingRunScriptCreation = nil
    }

    // MARK: - Palette

    func runScriptPaletteEnvironment(worktree: Worktree) -> RunScriptPaletteEnvironment {
        RunScriptPaletteEnvironment(
            scripts: { RunScriptStore.scripts(worktreeRoot: worktree.path) },
            isRunning: { [weak self] script in
                self?.runningScriptTab(for: script, in: worktree) != nil
            },
            run: { [weak self] script, console in self?.runOrFocusScript(script, in: worktree, console: console) },
            restart: { [weak self] script in self?.restartScript(script, in: worktree) },
            edit: { [weak self] script in self?.editScript(script, in: worktree) },
            newScript: { [weak self] scope in self?.newRunScript(scope: scope, in: worktree) }
        )
    }
}

/// Hosts the app's runs in run tabs: a terminal whose run leaf the core
/// observes, closed when the run is stopped or restarted.
@MainActor
final class AppRunLauncher: RunLauncher {
    weak var app: AppState?

    func refusal(for script: RunScript, in worktree: Worktree, project: ProjectConfig) -> String? {
        // The run command reaches the shell only through the rc-file
        // injection every startup script uses; any other shell would open
        // bare, so refuse instead of leaving an empty pane.
        guard let shell = app?.config.terminal.shell,
              !StartupScriptInstaller.supportsStartupScriptInjection(shell: shell)
        else { return nil }
        return "Run scripts require zsh or bash as your configured terminal shell (currently \((shell as NSString).lastPathComponent))."
    }

    func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch {
        guard let app else { throw CancellationError() }
        let tab = try await app.openTerminalTabPreparingRemoteZmxIfNeeded(
            for: request.worktree,
            startupScriptSuffix: request.command,
            includeUserStartupScript: true,
            titleOverride: request.script.displayName,
            runScriptKey: request.script.key,
            isHidden: request.isHidden
        )
        // A terminal with no run leaf gives nothing to observe.
        guard case .terminal(let terminalState) = tab, let sessionID = terminalState.runScriptLeafId else {
            return .unobservable
        }
        app.runFailureBriefs.cancelInFlight(worktreeID: request.worktree.id, scriptKey: request.script.key)
        return .hosted(sessionID: sessionID)
    }

    func hostsRun(scriptKey: String, worktreeID: String) -> Bool {
        app?.scriptTab(scriptKey: scriptKey, worktreeID: worktreeID) != nil
    }

    func endRunHost(scriptKey: String, worktreeID: String) {
        guard let app, let tab = app.scriptTab(scriptKey: scriptKey, worktreeID: worktreeID) else { return }
        app.closeTab(worktreeId: worktreeID, tabId: tab.id)
    }

    func endRunHost(sessionID: String, worktreeID: String) {
        guard let app,
              let tab = app.tabs.tabs(forWorktree: worktreeID).first(where: { tab in
                  guard case .terminal(let state) = tab else { return false }
                  return state.root.find(leafId: sessionID) != nil
              })
        else { return }
        app.closeTab(worktreeId: worktreeID, tabId: tab.id)
    }

    func hostSessionExists(_ sessionID: String) -> Bool {
        app?.terminal.registry.session(for: sessionID) != nil
    }

    func hostSessionIsIdle(_ sessionID: String) -> Bool {
        app?.runScriptSessionForegroundPidIsMissing(sessionID: sessionID) ?? false
    }

    func runDidFinish(_ record: RunRecord, completion: RunScriptCompletion, script: RunScript, worktree: Worktree, sessionID: String?) {
        app?.runScriptFinished(record, completion: completion, script: script, worktree: worktree, sessionID: sessionID ?? "")
    }
}
