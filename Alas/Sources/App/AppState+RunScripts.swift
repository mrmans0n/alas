import Foundation
import os

private let runScriptLogger = Logger(subsystem: "io.nlopez.alas", category: "RunScripts")

struct RunScriptCapturePaths: Equatable, Sendable {
    let transcript: String
    let completion: String
}

extension AppState {
    // MARK: - Launch

    /// Composes the startup-script suffix for a run: explicit `cd` (the
    /// terminal default cwd can be `lastUsed`), env exports scoped to the
    /// command line, then the invocation. Executables run directly so their
    /// shebang applies; other files run via /bin/sh.
    nonisolated static func runScriptStartupScript(
        script: RunScript,
        worktreeRoot: URL,
        branch: String,
        projectName: String,
        repoRoot: String,
        capturePaths: RunScriptCapturePaths? = nil
    ) throws -> String {
        let cwd = script.cwd.map { worktreeRoot.appendingPathComponent($0).path } ?? worktreeRoot.path
        let env = [
            "ALAS_WORKTREE_ROOT": worktreeRoot.path,
            "ALAS_REPO_ROOT": repoRoot,
            "ALAS_BRANCH": branch,
            "ALAS_PROJECT_NAME": projectName,
        ]
        let command: String
        let args: [String]
        if script.isExecutable {
            command = script.fileURL.path
            args = []
        } else {
            command = "/bin/sh"
            args = [script.fileURL.path]
        }
        let run = try shellCommand(
            command: command,
            args: args,
            env: env,
            exitOnCompletion: script.onExit == .close
        )
        let commandLine = try shellCommand(command: command, args: args, env: env)
        // A missing/misspelled `alas-cwd` must stop the run rather than fall
        // through and execute the script from wherever the shell happened to
        // start — that's silently dangerous for build/cleanup scripts.
        let prefix = "cd \(shellQuote(cwd)) || exit 1\n"
        guard let capturePaths else { return prefix + run }
        return capturedRunScript(
            commandLine: commandLine,
            workingDirectory: shellQuote(cwd),
            capturePaths: capturePaths,
            exitOnCompletion: script.onExit == .close
        )
    }

    nonisolated private static func capturedRunScript(
        commandLine: String,
        workingDirectory: String,
        capturePaths: RunScriptCapturePaths,
        exitOnCompletion: Bool
    ) -> String {
        let transcript = capturePathShellLiteral(capturePaths.transcript)
        let completion = capturePathShellLiteral(capturePaths.completion)
        let status = capturePathShellLiteral("\(capturePaths.completion).status")
        let transcriptDir = capturePathShellLiteral((capturePaths.transcript as NSString).deletingLastPathComponent)
        let completionDir = capturePathShellLiteral((capturePaths.completion as NSString).deletingLastPathComponent)
        let quotedCommandLine = shellQuote(commandLine)
        let quotedDarwinCommandLine = shellQuote("""
        \(commandLine)
        code=$?
        printf '%s\\n' "$code" > \(status)
        exit "$code"
        """)
        let finishLine = exitOnCompletion
            ? "\nexit \"$exit_code\""
            : "\nif [ \"$publish_failed\" = 1 ]; then\n  exit \"$exit_code\"\nfi\nreturn \"$exit_code\""
        return """
        __alas_run_script_errexit_was_set=0
        case $- in
          *e*) __alas_run_script_errexit_was_set=1 ;;
        esac
        if [ "$__alas_run_script_errexit_was_set" = 1 ]; then
          set +e
        fi
        __alas_run_script_capture() {
        local transcript=\(transcript)
        local completion=\(completion)
        local transcript_ready=0
        local completion_ready=0
        local publish_failed=0
        local setup_failed=0
        local alas_errexit_was_set=$__alas_run_script_errexit_was_set
        local private_umask result script_status exit_code tmp completed_at
        if [ "$alas_errexit_was_set" = 1 ]; then
          set +e
        fi
        if ! cd \(workingDirectory); then
          exit_code=1
          setup_failed=1
        fi
        if mkdir -p \(transcriptDir) 2>/dev/null && chmod 700 \(transcriptDir) 2>/dev/null; then
          transcript_ready=1
          find \(transcriptDir) -type f \\( -name '*.log' -o -name '*.done' -o -name '*.tmp' -o -name '*.body' -o -name '*.status' -o -name '*.snapshot' \\) -mtime +7 -exec rm -f {} + 2>/dev/null || true
        fi
        if mkdir -p \(completionDir) 2>/dev/null && chmod 700 \(completionDir) 2>/dev/null; then
          completion_ready=1
          find \(completionDir) -type f \\( -name '*.log' -o -name '*.done' -o -name '*.tmp' -o -name '*.body' -o -name '*.status' -o -name '*.snapshot' \\) -mtime +7 -exec rm -f {} + 2>/dev/null || true
        fi
        __alas_prepare_run_transcript() {
          private_umask=$(umask)
          umask 077
          : > "$transcript" 2>/dev/null && chmod 600 "$transcript" 2>/dev/null
          result=$?
          umask "$private_umask"
          return "$result"
        }
        if [ "$setup_failed" = 0 ] && [ "$transcript_ready" = 1 ] && command -v script >/dev/null 2>&1; then
          if [ "$(uname -s 2>/dev/null)" = Darwin ] && [ -x /usr/bin/script ]; then
            if __alas_prepare_run_transcript; then
              rm -f \(status)
              if /usr/bin/script -q "$transcript" /usr/bin/env -u SCRIPT /bin/sh -c \(quotedDarwinCommandLine); then
                script_status=0
              else
                script_status=$?
              fi
              if [ -f \(status) ]; then
                exit_code=$(cat \(status))
              else
                exit_code=$script_status
              fi
              rm -f \(status)
            else
              if \(commandLine); then
                exit_code=0
              else
                exit_code=$?
              fi
            fi
          elif script --version 2>/dev/null | grep -qi 'util-linux'; then
            if __alas_prepare_run_transcript; then
              if script -qefc \(quotedCommandLine) "$transcript"; then
                exit_code=0
              else
                exit_code=$?
              fi
            else
              if \(commandLine); then
                exit_code=0
              else
                exit_code=$?
              fi
            fi
          else
            if \(commandLine); then
              exit_code=0
            else
              exit_code=$?
            fi
          fi
        elif [ "$setup_failed" = 0 ]; then
          if \(commandLine); then
            exit_code=0
          else
            exit_code=$?
          fi
        fi
        if [ "$completion_ready" = 1 ]; then
          tmp="$completion.tmp"
          private_umask=$(umask)
          umask 077
          completed_at=$(perl -MTime::HiRes=time -e 'printf "%.6f\\n", time' 2>/dev/null || date +%s)
          if ! { printf '%s\\t%s\\n' "$exit_code" "$completed_at" > "$tmp" && mv "$tmp" "$completion"; }; then
            publish_failed=1
            rm -f "$tmp"
          fi
          umask "$private_umask"
        fi\(finishLine)
        }
        if __alas_run_script_capture; then
          __alas_run_script_status=0
        else
          __alas_run_script_status=$?
        fi
        __alas_finish_run_script_capture() {
          local captured_status=$1
          unset __alas_run_script_errexit_was_set __alas_run_script_status
          unset -f __alas_prepare_run_transcript __alas_run_script_capture __alas_finish_run_script_capture
          return "$captured_status"
        }
        if [ "$__alas_run_script_errexit_was_set" = 1 ]; then
          set +e
          if __alas_finish_run_script_capture "$__alas_run_script_status"; then
            __alas_run_script_final_status=0
          else
            __alas_run_script_final_status=$?
          fi
          __alas_run_script_return_status() {
            return "$__alas_run_script_final_status"
          }
          __alas_restore_run_script_errexit() {
            set -e
            if [ -n "${ZSH_VERSION-}" ]; then
              precmd_functions=("${precmd_functions[@]:#__alas_restore_run_script_errexit}")
            elif [ -n "${BASH_VERSION-}" ]; then
              case "$PROMPT_COMMAND" in
                "__alas_restore_run_script_errexit; "*) PROMPT_COMMAND=${PROMPT_COMMAND#__alas_restore_run_script_errexit; } ;;
                "__alas_restore_run_script_errexit") unset PROMPT_COMMAND ;;
              esac
            fi
            unset __alas_run_script_final_status
            unset -f __alas_run_script_return_status
            unset -f __alas_restore_run_script_errexit
          }
          if [ -n "${ZSH_VERSION-}" ]; then
            precmd_functions=(__alas_restore_run_script_errexit "${precmd_functions[@]}")
          elif [ -n "${BASH_VERSION-}" ]; then
            PROMPT_COMMAND="__alas_restore_run_script_errexit${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
          fi
          __alas_run_script_return_status
        else
          __alas_finish_run_script_capture "$__alas_run_script_status"
        fi
        """
    }

    nonisolated private static func capturePathShellLiteral(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return shellQuote(path) }
        return "\"$HOME/\(path.dropFirst(2).doubleQuotedShellEscaped)\""
    }

    /// The tab hosting this script in this worktree, live session or not.
    /// Stopping or restarting has to reach a stale tab too — otherwise a
    /// relaunch would leave the old one stranded beside the new one.
    func scriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        tabs.tabs(forWorktree: worktree.id).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.runScriptKey == script.key
        }
    }

    /// The script's tab *with a live shell behind it*. Used to decide whether
    /// there is a terminal worth jumping to — never to decide whether the
    /// command itself is still running; `runRecords` owns that.
    func runningScriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        tabs.tabs(forWorktree: worktree.id).first { tab in
            guard case .terminal(let state) = tab,
                  state.runScriptKey == script.key,
                  let runScriptLeafId = state.runScriptLeafId,
                  let leaf = state.root.find(leafId: runScriptLeafId)?.leaf
            else { return false }
            return terminal.registry.session(for: leaf.sessionId) != nil
        }
    }

    /// Enter/click semantics: focus the script's open tab when it exists,
    /// otherwise launch a new one. One tab per (script, worktree).
    func runOrFocusScript(_ script: RunScript, in worktree: Worktree) {
        if let existing = runningScriptTab(for: script, in: worktree) {
            activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
            return
        }
        launchScript(script, in: worktree)
    }

    func restartScript(_ script: RunScript, in worktree: Worktree) {
        let launchKey = PendingRunScriptLaunchKey(worktreeID: worktree.id, scriptKey: script.key)
        if pendingScriptLaunches[launchKey] != nil {
            stopScript(script, in: worktree)
            launchScript(script, in: worktree)
            return
        }
        if let existing = scriptTab(for: script, in: worktree) {
            let capture = stoppedRunHistoryCapture(worktreeID: worktree.id, scriptKey: script.key)
            let finalized = runRecords.markStopped(worktreeID: worktree.id, scriptKey: script.key, at: Date())
            archiveFinalizedRun(finalized, capture: capture)
            closeTab(worktreeId: worktree.id, tabId: existing.id)
        }
        launchScript(script, in: worktree)
    }

    /// Stop an in-flight run by closing the terminal that hosts it. The record
    /// is marked stopped *before* the close so the monitor-cancellation path
    /// can't relabel a deliberate stop as a lost process.
    func stopScript(_ script: RunScript, in worktree: Worktree) {
        let launchKey = PendingRunScriptLaunchKey(worktreeID: worktree.id, scriptKey: script.key)
        if let pending = pendingScriptLaunches.removeValue(forKey: launchKey) {
            let finalized = runRecords.markStopped(worktreeID: worktree.id, scriptKey: script.key, at: Date())
            archiveFinalizedRun(finalized, capture: .unavailable)
            pendingScriptLaunchTasks.removeValue(forKey: pending.id)?.cancel()
            return
        }
        guard let existing = scriptTab(for: script, in: worktree) else {
            // Nothing left to stop: whatever we thought was running is gone,
            // and we never saw it exit.
            let finalized = runRecords.markLostObservation(worktreeID: worktree.id, scriptKey: script.key, at: Date())
            archiveFinalizedRun(finalized, capture: .unavailable)
            return
        }
        let capture = stoppedRunHistoryCapture(worktreeID: worktree.id, scriptKey: script.key)
        let finalized = runRecords.markStopped(worktreeID: worktree.id, scriptKey: script.key, at: Date())
        archiveFinalizedRun(finalized, capture: capture)
        closeTab(worktreeId: worktree.id, tabId: existing.id)
    }

    /// Reveal the terminal a run is (or was) hosted in. Scoped to `worktree`
    /// so a same-named script in another worktree is never focused.
    func focusScriptTerminal(_ script: RunScript, in worktree: Worktree) {
        guard let existing = runningScriptTab(for: script, in: worktree) else { return }
        activateWorktreeCenterTab(worktreeId: worktree.id, tabId: existing.id)
    }

    /// Re-check active records whose terminal has gone away. Called when the
    /// Run tab appears, so reconnecting to a worktree settles uncertain runs
    /// instead of leaving them stuck on "Running".
    func reconcileRunRecords(worktreeID: String) {
        let now = Date()
        for record in runRecords.records(worktreeID: worktreeID) where record.status.isActive {
            guard let sessionID = record.sessionID else { continue }
            guard terminal.registry.session(for: sessionID) == nil else { continue }
            // A monitor may still be waiting on a completion file that outlives
            // the shell; only give up once nothing is observing the run.
            guard !runScriptCompletionTasks.values.contains(where: { $0.sessionID == sessionID }) else { continue }
            let finalized = runRecords.markLostObservation(runID: record.id, at: now)
            archiveFinalizedRun(finalized, capture: .unavailable)
        }
    }

    func runExecutionTarget(for script: RunScript, in worktree: Worktree) -> RunExecutionTarget {
        RunExecutionTarget(
            host: projects.first(where: { $0.id == worktree.projectId })?.host,
            workingDirectory: script.cwd.map { worktree.path.appendingPathComponent($0).path }
                ?? worktree.path.path
        )
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

    /// Who else holds the run's endpoint port right now. Reported, never acted
    /// on — Alas does not terminate a process it does not own.
    private func detectPortConflict(
        endpoint: URL?,
        target: RunExecutionTarget,
        excludingRunID: String
    ) -> RunPortConflict? {
        guard let port = endpoint?.runEndpointPort else { return nil }
        if let owner = runRecords.activeRunOwningPort(port, host: target.host, excludingRunID: excludingRunID) {
            return .ownedByRun(
                worktreeID: owner.worktreeID,
                branch: owner.branch,
                scriptName: owner.scriptName
            )
        }
        // A bind probe only means something for ports on this machine.
        guard !target.isRemote, RunPortProbe.isLocalPortInUse(port) else { return nil }
        return .externalProcess
    }

    private func launchScript(_ script: RunScript, in worktree: Worktree) {
        // The tab that would satisfy `runningScriptTab` isn't registered
        // until this launch's async Task finishes, so two invocations before
        // that (double-click, repeated Enter) would both see "not running"
        // and both launch. Close that window with a synchronous in-flight
        // guard instead.
        let launchKey = PendingRunScriptLaunchKey(worktreeID: worktree.id, scriptKey: script.key)
        guard pendingScriptLaunches[launchKey] == nil else { return }

        // Global scripts live in local Application Support and are read by
        // path, not content — launching one into a remote worktree would ship
        // a Mac-only path into the SSH-launched remote shell, which can't see
        // it. Remote repo scripts are discovered through the remote file layer,
        // so their absolute path is intentionally not local-file-system
        // reachable here.
        if script.scope == .global, worktree.path.isRemoteAlasPath {
            showFileActionError(
                title: "Run Script Failed",
                message: "Global scripts run on your Mac and can't be launched on a remote worktree yet."
            )
            return
        }
        let requiresLocalScriptPath = !(script.scope == .repo && worktree.path.isRemoteAlasPath)
        guard !requiresLocalScriptPath || FileManager.default.fileExists(atPath: script.fileURL.path) else {
            showFileActionError(
                title: "Run Script Failed",
                message: "\(script.fileName) no longer exists on disk."
            )
            return
        }
        // The run command only ever reaches the shell via the same rc-file
        // injection StartupScriptInstaller uses for every other startup
        // script — for a shell it doesn't know how to inject into, `plan`
        // silently drops the script and just opens a bare login shell. Fail
        // loudly here instead of leaving the user staring at an empty pane.
        guard StartupScriptInstaller.supportsStartupScriptInjection(shell: config.terminal.shell) else {
            showFileActionError(
                title: "Run Script Failed",
                message: "Run scripts require zsh or bash as your configured terminal shell (currently \((config.terminal.shell as NSString).lastPathComponent))."
            )
            return
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return }
        // Claim the slot synchronously, alongside `pendingScriptLaunches`, so
        // the row flips to "Starting" on the same turn the user clicked and a
        // second click can't open a second run behind the first one's back.
        let runID = UUID().uuidString
        let target = runExecutionTarget(for: script, in: worktree)
        let conflict = detectPortConflict(endpoint: script.endpoint, target: target, excludingRunID: runID)
        let displacedRecord = runRecords.begin(RunRecord(
            id: runID,
            scriptKey: script.key,
            scriptName: script.displayName,
            worktreeID: worktree.id,
            branch: worktree.branch,
            target: target,
            endpoint: script.endpoint,
            status: .starting,
            startedAt: Date(),
            portConflict: conflict
        ))

        let launchID = UUID()
        pendingScriptLaunches[launchKey] = PendingRunScriptLaunch(
            id: launchID,
            worktreeID: worktree.id,
            scriptKey: script.key
        )
        let launchTask = Task { @MainActor in
            defer {
                if pendingScriptLaunches[launchKey]?.id == launchID {
                    pendingScriptLaunches.removeValue(forKey: launchKey)
                }
                pendingScriptLaunchTasks.removeValue(forKey: launchID)
            }
            let captureLocation: RunScriptCaptureLocation
            do {
                captureLocation = try RunScriptCompletionMonitor.paths(runID: runID, host: project.host)
                let suffix = try Self.runScriptStartupScript(
                    script: script,
                    worktreeRoot: worktree.path,
                    branch: worktree.branch,
                    projectName: project.name,
                    repoRoot: project.path,
                    capturePaths: captureLocation.paths
                )
                do {
                    let tab = try await openTerminalTabPreparingRemoteZmxIfNeeded(
                        for: worktree,
                        startupScriptSuffix: suffix,
                        includeUserStartupScript: true,
                        titleOverride: script.displayName,
                        runScriptKey: script.key
                    )
                    if Task.isCancelled {
                        closeTab(worktreeId: worktree.id, tabId: tab.id)
                        return
                    }
                    guard case .terminal(let terminalState) = tab,
                          let sessionID = terminalState.runScriptLeafId
                    else {
                        // A terminal with no run leaf gives us nothing to
                        // observe; say so instead of leaving the row starting.
                        cancelRunScriptCompletionTask(runID: runID, location: captureLocation)
                        return
                    }
                    startRunScriptCompletionMonitor(
                        runID: runID,
                        sessionID: sessionID,
                        location: captureLocation,
                        script: script,
                        worktree: worktree
                    )
                    runRecords.markRunning(runID: runID, sessionID: sessionID)
                    if runScriptSessionForegroundPidIsMissing(sessionID: sessionID) {
                        cancelRunScriptCompletionTasksIfSessionStillExited(sessionID: sessionID, after: .seconds(2), includeRemote: false)
                        cancelRunScriptCompletionTasksIfSessionStillExited(sessionID: sessionID, after: .seconds(30))
                    }
                } catch {
                    releaseRunHistoryCaptureInBackground(.location(captureLocation))
                    throw error
                }
            } catch {
                if Task.isCancelled { return }
                // The command never started, so the previous outcome is still
                // the most recent thing we actually observed — put it back.
                runRecords.rollback(runID: runID, to: displacedRecord)
                showFileActionError(title: "Run Script Failed", message: error.localizedDescription)
            }
        }
        pendingScriptLaunchTasks[launchID] = launchTask
    }

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
    }

    func openRunReport(worktreeID: String, runID: String) {
        let tab = tabs.openOrFocusRunReport(worktreeId: worktreeID, runID: runID)
        activateWorktreeCenterTab(worktreeId: worktreeID, tabId: tab.id)
        acknowledgeAttentionSurface(worktreeID: worktreeID, target: .runScriptFailure(failureID: runID))
    }

    func openTransientRunReport(_ entry: RunHistoryEntry) {
        transientRunReports[runReportKey(worktreeID: entry.worktreeID, runID: entry.id)] = entry
        noteRunHistoryChanged(worktreeID: entry.worktreeID)
        let tab = tabs.openOrFocusRunReport(worktreeId: entry.worktreeID, runID: entry.id, isTransient: true)
        activateWorktreeCenterTab(worktreeId: entry.worktreeID, tabId: tab.id)
        acknowledgeAttentionSurface(worktreeID: entry.worktreeID, target: .runScriptFailure(failureID: entry.id))
    }

    func transientRunReport(worktreeID: String, runID: String) -> RunHistoryEntry? {
        transientRunReports[runReportKey(worktreeID: worktreeID, runID: runID)]
    }

    func hasRunReport(worktreeID: String, runID: String) -> Bool {
        transientRunReport(worktreeID: worktreeID, runID: runID) != nil
            || durableRunReportIDsByWorktreeID[worktreeID, default: []].contains(runID)
    }

    func hasPersistedRunReport(worktreeID: String, runID: String) async -> Bool {
        await flushRunHistoryPersistence(worktreeID: worktreeID)
        guard let runHistoryStore,
              (try? await runHistoryStore.entry(id: runID))?.worktreeID == worktreeID
        else { return false }
        durableRunReportIDsByWorktreeID[worktreeID, default: []].insert(runID)
        return true
    }

    func clearRunHistory(worktreeID: String) {
        let cutoff = Date()
        guard let runHistoryStore else {
            transientRunReports = transientRunReports.filter { $0.value.worktreeID != worktreeID }
            tabs.closeRunReports(worktreeId: worktreeID)
            return
        }
        Task { @MainActor [weak self, runHistoryStore] in
            guard let self else { return }
            await self.flushRunHistoryPersistence(worktreeID: worktreeID)
            do {
                try await runHistoryStore.clear(worktreeID: worktreeID, finishedOnOrBefore: cutoff)
                self.runRecords.purgeFinished(worktreeID: worktreeID, finishedOnOrBefore: cutoff)
                self.durableRunReportIDsByWorktreeID[worktreeID] = try await runHistoryStore.ids(worktreeID: worktreeID)
                self.transientRunReports = self.transientRunReports.filter { $0.value.worktreeID != worktreeID }
                self.tabs.closeRunReports(worktreeId: worktreeID)
                self.noteRunHistoryChanged(worktreeID: worktreeID)
            } catch {
                self.runHistoryError = "Could not clear run history: \(error.localizedDescription)"
                self.showFileActionError(title: "Run History Failed", message: "Could not clear run history: \(error.localizedDescription)")
            }
        }
    }

    private func runReportKey(worktreeID: String, runID: String) -> String {
        "\(worktreeID)\u{0}\(runID)"
    }

    func noteRunHistoryChanged(worktreeID: String) {
        runHistoryRevisionsByWorktreeID[worktreeID, default: 0] += 1
        runHistoryRevision += 1
    }

    func runHistoryRevision(worktreeID: String) -> Int {
        runHistoryRevisionsByWorktreeID[worktreeID, default: 0]
    }

    @MainActor
    func reloadDurableRunReportIDs(worktreeID: String) async {
        guard let runHistoryStore else {
            durableRunReportIDsByWorktreeID[worktreeID] = []
            return
        }
        do {
            durableRunReportIDsByWorktreeID[worktreeID] = try await runHistoryStore.ids(worktreeID: worktreeID)
        } catch {
            durableRunReportIDsByWorktreeID[worktreeID] = []
        }
    }

    func waitForRunScriptCompletionTasksForTesting() async {
        let tasks = runScriptCompletionTasks.values.map { $0.task }
        for task in tasks {
            await task.value
        }
    }

    var runScriptCompletionTaskCountForTesting: Int {
        runScriptCompletionTasks.count
    }

    private enum RunHistoryCapture {
        case completion(RunScriptCompletion)
        case location(RunScriptCaptureLocation)
        case snapshot(RunScriptTranscriptSnapshot, cleanup: RunScriptCaptureLocation)
        case unavailable
    }

    private func stoppedRunHistoryCapture(worktreeID: String, scriptKey: String) -> RunHistoryCapture {
        guard let runID = runRecords.record(worktreeID: worktreeID, scriptKey: scriptKey)?.id,
              let entry = runScriptCompletionTasks.removeValue(forKey: runID)
        else { return .unavailable }
        let capture = runHistoryCaptureBeforeCancelling(entry.location)
        entry.task.cancel()
        return capture
    }

    private func runHistoryCaptureBeforeCancelling(_ location: RunScriptCaptureLocation) -> RunHistoryCapture {
        if let snapshot = RunScriptCompletionMonitor.localSnapshot(for: location) {
            return .snapshot(snapshot, cleanup: location)
        }
        return .location(location)
    }

    private func runHistoryCapture(for error: Error, location: RunScriptCaptureLocation) -> RunHistoryCapture {
        if case let RunScriptCompletionMonitor.MonitorError.malformedStatus(snapshot) = error {
            return .snapshot(snapshot, cleanup: location)
        }
        return .location(location)
    }

    private func archiveFinalizedRun(_ record: RunRecord?, capture: RunHistoryCapture) {
        guard let record,
              let entry = Self.runHistoryEntry(for: record, output: .unavailable),
              let runHistoryStore
        else {
            releaseRunHistoryCaptureInBackground(capture)
            return
        }
        runHistoryPersistenceTaskWorktreeIDs[record.id] = record.worktreeID
        runHistoryPersistenceTasks[record.id] = Task { @MainActor [weak self, runHistoryStore] in
            let output = await Self.runHistoryOutput(for: capture)
            let entry = Self.runHistoryEntry(for: record, output: output) ?? entry
            do {
                let inserted = try await runHistoryStore.append(entry)
                if inserted {
                    self?.durableRunReportIDsByWorktreeID[record.worktreeID] = try await runHistoryStore.ids(worktreeID: record.worktreeID)
                    self?.noteRunHistoryChanged(worktreeID: record.worktreeID)
                }
            } catch {
                self?.runHistoryError = "Could not save run history: \(error.localizedDescription)"
                self?.showFileActionError(title: "Run History Failed", message: "Could not save run history: \(error.localizedDescription)")
                runScriptLogger.error(
                    "Could not persist run \(record.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            await self?.releaseRunHistoryCapture(capture)
            self?.runHistoryPersistenceTasks.removeValue(forKey: record.id)
            self?.runHistoryPersistenceTaskWorktreeIDs.removeValue(forKey: record.id)
        }
    }

    private static func runHistoryEntry(for record: RunRecord, output: RunHistoryOutput) -> RunHistoryEntry? {
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

    private static func runHistoryOutput(for capture: RunHistoryCapture) async -> RunHistoryOutput {
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

    private func releaseRunHistoryCaptureInBackground(_ capture: RunHistoryCapture) {
        guard let location = cleanupLocation(for: capture) else { return }
        cleanupCaptureLocation(location)
        Task {
            await RunScriptCompletionMonitor.cleanupRemoteCapture(for: location)
        }
    }

    private func releaseRunHistoryCapture(_ capture: RunHistoryCapture) async {
        guard let location = cleanupLocation(for: capture) else { return }
        cleanupCaptureLocation(location)
        await RunScriptCompletionMonitor.cleanupRemoteCapture(for: location)
    }

    private func cleanupLocation(for capture: RunHistoryCapture) -> RunScriptCaptureLocation? {
        let location: RunScriptCaptureLocation
        switch capture {
        case let .location(captured), let .snapshot(_, cleanup: captured):
            location = captured
        case .completion, .unavailable:
            return nil
        }
        return location
    }

    func flushRunHistoryPersistence(worktreeID: String? = nil) async {
        let tasks: [Task<Void, Never>] = runHistoryPersistenceTasks.compactMap { entry in
            let (runID, task) = entry
            guard worktreeID == nil || runHistoryPersistenceTaskWorktreeIDs[runID] == worktreeID else { return nil }
            return task
        }
        for task in tasks {
            await task.value
        }
    }

    private func startRunScriptCompletionMonitor(
        runID: String,
        sessionID: String,
        location: RunScriptCaptureLocation,
        script: RunScript,
        worktree: Worktree
    ) {
        runScriptCompletionTasks[runID] = (
            worktreeID: worktree.id,
            sessionID: sessionID,
            location: location,
            task: Task { @MainActor [weak self] in
                guard let self else { return }
                defer { runScriptCompletionTasks.removeValue(forKey: runID) }
                do {
                    let completion = try await runScriptCompletionWaiter(location)
                    let observedAt = Date()
                    guard runRecords.isCurrentActiveRun(
                        runID: runID,
                        worktreeID: worktree.id,
                        scriptKey: script.key
                    ) else { return }
                    harness.notifications.notifyRunScriptFinished(
                        scriptName: script.displayName,
                        exitCode: completion.exitCode,
                        projectId: worktree.projectId,
                        worktreeId: worktree.id,
                        sessionId: sessionID,
                        runID: runID
                    )
                    guard completion.exitCode != 0 else {
                        let finalized = runRecords.finish(runID: runID, outcome: .succeeded, at: observedAt)
                        archiveFinalizedRun(finalized, capture: .completion(completion))
                        retireRunScriptAttention(scriptKey: script.key, worktree: worktree, at: observedAt)
                        inAppNotifications.post(
                            "\(script.displayName) succeeded",
                            severity: .success,
                            worktreeID: worktree.id
                        )
                        return
                    }
                    let failureID = runID
                    let finalized = runRecords.finish(
                        runID: runID,
                        outcome: .failed(exitCode: completion.exitCode),
                        at: observedAt,
                        failureID: failureID
                    )
                    archiveFinalizedRun(finalized, capture: .completion(completion))
                    let failure = RunScriptFailure(
                        id: failureID,
                        runID: runID,
                        scriptKey: script.key,
                        scriptName: script.displayName,
                        worktreeID: worktree.id,
                        branch: worktree.branch,
                        exitCode: completion.exitCode,
                        completedAt: observedAt
                    )
                    retireRunScriptAttention(scriptKey: script.key, worktree: worktree, at: observedAt)
                    runScriptFailureQueue.append(failure)
                    if let context = attentionContext(for: worktree) {
                        for observation in AttentionProducer.script(
                            failure: failure, owner: context.owner, display: context.display
                        ) {
                            observeAttention(observation, at: failure.completedAt)
                        }
                    }
                } catch is CancellationError {
                    // `cancelRunScriptCompletionTask` already recorded the
                    // lost observation; it owns that transition.
                } catch {
                    // The waiter failed (dropped SSH, unreadable completion
                    // file). We never saw an exit status, so we can't claim one.
                    let capture = runHistoryCapture(for: error, location: location)
                    if let finalized = runRecords.markLostObservation(runID: runID, at: Date()) {
                        archiveFinalizedRun(finalized, capture: capture)
                    } else if runHistoryPersistenceTasks[runID] == nil {
                        releaseRunHistoryCaptureInBackground(capture)
                    }
                    runScriptLogger.error(
                        "Run script completion monitor failed for run \(runID, privacy: .public) at \(String(describing: location), privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        )
    }
    private func cancelRunScriptCompletionTask(runID: String, location: RunScriptCaptureLocation) {
        let capture = runHistoryCaptureBeforeCancelling(location)
        runScriptCompletionTasks.removeValue(forKey: runID)?.task.cancel()
        if let finalized = runRecords.markLostObservation(runID: runID, at: Date()) {
            archiveFinalizedRun(finalized, capture: capture)
        } else if runHistoryPersistenceTasks[runID] == nil {
            releaseRunHistoryCaptureInBackground(.location(location))
        }
    }

    /// Gives up on observing a run. Every caller reaches here because the run's
    /// shell went away before the command reported an exit status, so the
    /// record settles on `unknown` — never on success.
    private func cancelRunScriptCompletionTask(runID: String) {
        guard let entry = runScriptCompletionTasks.removeValue(forKey: runID) else { return }
        let capture = runHistoryCaptureBeforeCancelling(entry.location)
        entry.task.cancel()
        if let finalized = runRecords.markLostObservation(runID: runID, at: Date()) {
            archiveFinalizedRun(finalized, capture: capture)
        } else if runHistoryPersistenceTasks[runID] == nil {
            releaseRunHistoryCaptureInBackground(.location(entry.location))
        }
    }

    func cancelRunScriptCompletionTasks(
        sessionID: String,
        after delay: Duration? = nil,
        includeRemote: Bool = true
    ) {
        let runIDs = runScriptCompletionTasks.compactMap { runID, entry -> String? in
            if !includeRemote, case .remote = entry.location { return nil }
            return entry.sessionID == sessionID ? runID : nil
        }
        guard let delay else {
            for runID in runIDs { cancelRunScriptCompletionTask(runID: runID) }
            return
        }
        for runID in runIDs {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard self?.runScriptCompletionTasks[runID]?.sessionID == sessionID else { return }
                self?.cancelRunScriptCompletionTask(runID: runID)
            }
        }
    }

    func scheduleRunScriptCompletionCancellation(sessionID: String) {
        cancelRunScriptCompletionTasks(sessionID: sessionID, after: .seconds(2), includeRemote: false)
        cancelRunScriptCompletionTasks(sessionID: sessionID, after: .seconds(30))
    }

    private func cancelRunScriptCompletionTasksIfSessionStillExited(
        sessionID: String,
        after delay: Duration,
        includeRemote: Bool = true
    ) {
        let runIDs = runScriptCompletionTasks.compactMap { runID, entry -> String? in
            if !includeRemote, case .remote = entry.location { return nil }
            return entry.sessionID == sessionID ? runID : nil
        }
        for runID in runIDs {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self,
                      self.runScriptCompletionTasks[runID]?.sessionID == sessionID,
                      self.runScriptSessionForegroundPidIsMissing(sessionID: sessionID)
                else { return }
                self.cancelRunScriptCompletionTask(runID: runID)
            }
        }
    }

    private func runScriptSessionForegroundPidIsMissing(sessionID: String) -> Bool {
        terminal.registry.session(for: sessionID)?.surface.foregroundPid == nil
            && harness.detector.foregroundPid(sessionId: sessionID) == nil
    }

    @discardableResult
    func cleanupRunScriptState(
        worktreeID: String,
        purgeFailures: Bool = true,
        purgeHistory: Bool = true
    ) -> Task<Void, Never>? {
        var historyPurgeTask: Task<Void, Never>?
        cancelPendingRunScriptLaunches(worktreeID: worktreeID)
        for (runID, entry) in runScriptCompletionTasks where entry.worktreeID == worktreeID {
            if purgeFailures {
                let capture = purgeHistory ? .location(entry.location) : runHistoryCaptureBeforeCancelling(entry.location)
                runScriptCompletionTasks.removeValue(forKey: runID)?.task.cancel()
                if purgeHistory {
                    releaseRunHistoryCaptureInBackground(capture)
                } else {
                    let finalized = runRecords.markLostObservation(runID: runID, at: Date())
                    archiveFinalizedRun(finalized, capture: capture)
                }
            } else {
                cancelRunScriptCompletionTask(runID: runID)
            }
        }
        if purgeFailures {
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
            runRecords.purge(worktreeID: worktreeID)
            runScriptFailureQueue.purge(worktreeID: worktreeID)
            transientRunReports = transientRunReports.filter { $0.value.worktreeID != worktreeID }
            durableRunReportIDsByWorktreeID[worktreeID] = []
            tabs.closeRunReports(worktreeId: worktreeID)
            if purgeHistory, let runHistoryStore {
                historyPurgeTask = Task { @MainActor [weak self, runHistoryStore] in
                    await self?.flushRunHistoryPersistence(worktreeID: worktreeID)
                    do {
                        try await runHistoryStore.purge(worktreeID: worktreeID)
                        self?.noteRunHistoryChanged(worktreeID: worktreeID)
                    } catch {
                        let message = "Could not purge run history: \(error.localizedDescription)"
                        self?.runHistoryError = message
                        self?.showFileActionError(title: "Run History Failed", message: message)
                    }
                }
            }
        } else {
            let now = Date()
            for record in runRecords.records(worktreeID: worktreeID) where record.status.isActive {
                let finalized = runRecords.markLostObservation(runID: record.id, at: now)
                archiveFinalizedRun(finalized, capture: .unavailable)
            }
        }
        return historyPurgeTask
    }

    func cancelPendingRunScriptLaunches(worktreeID: String? = nil) {
        let now = Date()
        let pendingKeys = pendingScriptLaunches.compactMap { key, pending -> PendingRunScriptLaunchKey? in
            guard let worktreeID else { return key }
            return pending.worktreeID == worktreeID ? key : nil
        }
        for key in pendingKeys {
            guard let pending = pendingScriptLaunches.removeValue(forKey: key) else { continue }
            pendingScriptLaunchTasks.removeValue(forKey: pending.id)?.cancel()
            let finalized = runRecords.markStopped(worktreeID: pending.worktreeID, scriptKey: pending.scriptKey, at: now)
            archiveFinalizedRun(finalized, capture: .unavailable)
        }
    }

    func cancelAllRunScriptCompletionTasks() {
        let now = Date()
        for (runID, entry) in runScriptCompletionTasks {
            let capture = runHistoryCaptureBeforeCancelling(entry.location)
            entry.task.cancel()
            let finalized = runRecords.markLostObservation(runID: runID, at: now)
            archiveFinalizedRun(finalized, capture: capture)
        }
        runScriptCompletionTasks.removeAll()
    }

    private func cleanupCaptureLocation(_ location: RunScriptCaptureLocation) {
        guard case let .local(paths) = location else { return }
        try? FileManager.default.removeItem(atPath: paths.transcript)
        try? FileManager.default.removeItem(atPath: paths.completion)
        try? FileManager.default.removeItem(atPath: "\(paths.completion).tmp")
        try? FileManager.default.removeItem(atPath: "\(paths.completion).status")
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
            run: { [weak self] script in self?.runOrFocusScript(script, in: worktree) },
            restart: { [weak self] script in self?.restartScript(script, in: worktree) },
            edit: { [weak self] script in self?.editScript(script, in: worktree) },
            newScript: { [weak self] scope in self?.newRunScript(scope: scope, in: worktree) }
        )
    }
}

private extension StringProtocol {
    var doubleQuotedShellEscaped: String {
        String(self)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}
