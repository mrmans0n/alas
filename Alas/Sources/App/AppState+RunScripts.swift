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
            : "\nif [ \"$publish_failed\" = 1 ]; then\n  exit \"$exit_code\"\nfi\nif [ \"$alas_errexit_was_set\" = 1 ]; then\n  set -e\nfi\nreturn \"$exit_code\""
        return """
        __alas_run_script_errexit_was_set=0
        case $- in
          *e*) __alas_run_script_errexit_was_set=1 ;;
        esac
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
          find \(transcriptDir) -type f \\( -name '*.log' -o -name '*.done' -o -name '*.tmp' -o -name '*.body' -o -name '*.status' \\) -mtime +7 -exec rm -f {} + 2>/dev/null || true
        fi
        if mkdir -p \(completionDir) 2>/dev/null && chmod 700 \(completionDir) 2>/dev/null; then
          completion_ready=1
          find \(completionDir) -type f \\( -name '*.log' -o -name '*.done' -o -name '*.tmp' -o -name '*.body' -o -name '*.status' \\) -mtime +7 -exec rm -f {} + 2>/dev/null || true
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
          unset __alas_run_script_errexit_was_set __alas_run_script_status
          unset -f __alas_prepare_run_transcript __alas_run_script_capture __alas_finish_run_script_capture
        else
          __alas_finish_run_script_capture "$__alas_run_script_status"
        fi
        """
    }

    nonisolated private static func capturePathShellLiteral(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return shellQuote(path) }
        return "\"$HOME/\(path.dropFirst(2).doubleQuotedShellEscaped)\""
    }

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
        if let existing = runningScriptTab(for: script, in: worktree) {
            closeTab(worktreeId: worktree.id, tabId: existing.id)
        }
        launchScript(script, in: worktree)
    }

    private func launchScript(_ script: RunScript, in worktree: Worktree) {
        // The tab that would satisfy `runningScriptTab` isn't registered
        // until this launch's async Task finishes, so two invocations before
        // that (double-click, repeated Enter) would both see "not running"
        // and both launch. Close that window with a synchronous in-flight
        // guard instead.
        let launchKey = "\(worktree.id):\(script.key)"
        guard !pendingScriptLaunches.contains(launchKey) else { return }

        // Global scripts live in local Application Support and are read by
        // path, not content — launching one into a remote worktree would ship
        // a Mac-only path into the SSH-launched remote shell, which can't see
        // it. Repo scripts aren't affected: RunScriptStore only discovers them
        // from a locally-reachable worktree root in the first place.
        if script.scope == .global, worktree.path.isRemoteAlasPath {
            showFileActionError(
                title: "Run Script Failed",
                message: "Global scripts run on your Mac and can't be launched on a remote worktree yet."
            )
            return
        }
        guard FileManager.default.fileExists(atPath: script.fileURL.path) else {
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
        pendingScriptLaunches.insert(launchKey)
        Task { @MainActor in
            defer { pendingScriptLaunches.remove(launchKey) }
            let runID = UUID().uuidString
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
                    guard case .terminal(let terminalState) = tab,
                          let sessionID = terminalState.runScriptLeafId
                    else { return }
                    startRunScriptCompletionMonitor(
                        runID: runID,
                        sessionID: sessionID,
                        location: captureLocation,
                        script: script,
                        worktree: worktree
                    )
                    if runScriptSessionForegroundPidIsMissing(sessionID: sessionID) {
                        cancelRunScriptCompletionTasksIfSessionStillExited(sessionID: sessionID, after: .seconds(2), includeRemote: false)
                        cancelRunScriptCompletionTasksIfSessionStillExited(sessionID: sessionID, after: .seconds(30))
                    }
                } catch {
                    cancelRunScriptCompletionTask(runID: runID, location: captureLocation)
                    throw error
                }
            } catch {
                showFileActionError(title: "Run Script Failed", message: error.localizedDescription)
            }
        }
    }

    func runScriptFailures(in worktreeID: String) -> [RunScriptFailure] {
        runScriptFailureQueue.failures(for: worktreeID)
    }

    func dismissRunScriptFailure(id: String, worktreeID: String) {
        runScriptFailureQueue.dismiss(id: id, worktreeID: worktreeID)
        if selectedRunScriptFailure?.id == id, selectedRunScriptFailure?.worktreeID == worktreeID {
            selectedRunScriptFailure = nil
        }
    }

    func presentRunScriptFailure(_ failure: RunScriptFailure) {
        selectedRunScriptFailure = failure
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
                    guard completion.exitCode != 0 else { return }
                    let capturedOutput: RunScriptCapturedOutput
                    if let transcript = completion.transcript {
                        let snapshot = ANSIPlainTextSnapshot.tail(
                            from: transcript,
                            byteLimit: RunScriptCompletionMonitor.outputByteLimit,
                            normalizesCRLF: true
                        )
                        capturedOutput = .available(
                            text: snapshot.text,
                            truncated: completion.truncated || snapshot.truncated
                        )
                    } else {
                        capturedOutput = .unavailable
                    }
                    runScriptFailureQueue.append(RunScriptFailure(
                        id: UUID().uuidString,
                        runID: runID,
                        scriptKey: script.key,
                        scriptName: script.displayName,
                        worktreeID: worktree.id,
                        branch: worktree.branch,
                        exitCode: completion.exitCode,
                        completedAt: completion.completedAt,
                        capturedOutput: capturedOutput
                    ))
                } catch is CancellationError {
                } catch {
                    runScriptLogger.error(
                        "Run script completion monitor failed for run \(runID, privacy: .public) at \(String(describing: location), privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                }
            }
        )
    }

    private func cancelRunScriptCompletionTask(runID: String, location: RunScriptCaptureLocation) {
        runScriptCompletionTasks.removeValue(forKey: runID)?.task.cancel()
        cleanupCaptureLocation(location)
    }

    private func cancelRunScriptCompletionTask(runID: String) {
        guard let entry = runScriptCompletionTasks.removeValue(forKey: runID) else { return }
        entry.task.cancel()
        cleanupCaptureLocation(entry.location)
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

    func cleanupRunScriptState(worktreeID: String, purgeFailures: Bool = true) {
        for (runID, entry) in runScriptCompletionTasks where entry.worktreeID == worktreeID {
            runScriptCompletionTasks.removeValue(forKey: runID)?.task.cancel()
            cleanupCaptureLocation(entry.location)
        }
        if purgeFailures {
            runScriptFailureQueue.purge(worktreeID: worktreeID)
        }
        if purgeFailures, selectedRunScriptFailure?.worktreeID == worktreeID {
            selectedRunScriptFailure = nil
        }
    }

    func cancelAllRunScriptCompletionTasks() {
        for entry in runScriptCompletionTasks.values {
            entry.task.cancel()
            cleanupCaptureLocation(entry.location)
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
            repositoryName: project.name
        )
    }

    func createPendingRunScript(
        name: String,
        onExit: RunScriptOnExit,
        globalDir: URL = Paths.runScriptsGlobalDir
    ) throws {
        guard let presentation = pendingRunScriptCreation,
              let worktree = worktree(withId: presentation.worktreeId),
              worktree.projectId == presentation.projectId
        else {
            throw RunScriptCreationError.worktreeUnavailable
        }

        let url = try RunScriptCreator.create(
            scope: presentation.scope,
            name: name,
            onExit: onExit,
            worktreeRoot: worktree.path,
            globalDir: globalDir
        )

        switch presentation.scope {
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
        pendingRunScriptCreation = nil
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
