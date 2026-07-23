import Foundation

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
        repoRoot: String
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
        return "cd \(shellQuote(cwd))\n\(run)"
    }

    func runningScriptTab(for script: RunScript, in worktree: Worktree) -> Tab? {
        tabs.terminalTab(withRunScriptKey: script.key, worktreeId: worktree.id)
    }

    /// Enter/click semantics: focus the script's open tab when it exists,
    /// otherwise launch a new one. One tab per (script, worktree).
    func runOrFocusScript(_ script: RunScript, in worktree: Worktree) {
        if let existing = runningScriptTab(for: script, in: worktree) {
            tabs.activate(worktreeId: worktree.id, tabId: existing.id)
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
        guard FileManager.default.fileExists(atPath: script.fileURL.path) else {
            showFileActionError(
                title: "Run Script Failed",
                message: "\(script.fileName) no longer exists on disk."
            )
            return
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else { return }
        Task { @MainActor in
            do {
                let suffix = try Self.runScriptStartupScript(
                    script: script,
                    worktreeRoot: worktree.path,
                    branch: worktree.branch,
                    projectName: project.name,
                    repoRoot: project.path
                )
                _ = try await openTerminalTabPreparingRemoteZmxIfNeeded(
                    for: worktree,
                    startupScriptSuffix: suffix,
                    titleOverride: script.displayName,
                    runScriptKey: script.key
                )
            } catch {
                showFileActionError(title: "Run Script Failed", message: error.localizedDescription)
            }
        }
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
                revealCharacter: nil
            )
        }
    }
}
