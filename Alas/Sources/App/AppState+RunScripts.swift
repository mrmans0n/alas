import AppKit
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
        // A missing/misspelled `alas-cwd` must stop the run rather than fall
        // through and execute the script from wherever the shell happened to
        // start — that's silently dangerous for build/cleanup scripts.
        return "cd \(shellQuote(cwd)) || exit 1\n\(run)"
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
        guard let name = promptForRunScriptName() else { return }
        let dir = scope == .repo
            ? RunScriptStore.repoScriptsDir(worktreeRoot: worktree.path)
            : Paths.runScriptsGlobalDir
        let url = dir.appendingPathComponent(RunScriptTemplate.fileName(for: name))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileWriteFileExists, userInfo: [
                    NSLocalizedDescriptionKey: "A script named \"\(url.lastPathComponent)\" already exists."
                ])
            }
            try RunScriptTemplate.contents(name: name).data(using: .utf8)!
                .write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            showFileActionError(title: "New Script Failed", message: error.localizedDescription)
            return
        }
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

    private func promptForRunScriptName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Run Script"
        alert.informativeText = "Name for the new script."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Dev Server"
        // NSAlert doesn't reliably cascade the app's forced dark appearance
        // (WindowAppearance.apply) to a manually-added accessory view, which
        // otherwise leaves the bezel rendering with a mismatched, muddy tint.
        field.appearance = NSApp.effectiveAppearance
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
