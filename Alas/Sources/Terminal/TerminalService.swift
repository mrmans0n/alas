// TerminalService.swift
// Façade exposed to AppState. Owns the single Ghostty.App instance, the global
// config file, and the registry of live terminal sessions.

import Foundation
import AppKit
import Observation

/// Façade exposed to AppState. Owns the single Ghostty.App instance, the global
/// config file, and the registry of live terminal sessions.
@MainActor
@Observable
final class TerminalService {
    let registry = SessionRegistry()
    private(set) var app: AlasGhostty.App?
    private var lastConfigSig: String?
    var socketPath: String?

    /// Build the global config file for this app + theme combination, then
    /// (re)create the AlasGhostty.App if the config has changed materially.
    /// Call this on launch and whenever theme/terminal settings change.
    func ensureApp(cfg: AppConfig.Terminal, theme: Theme) throws {
        let configURL = Paths.appSupportRoot.appendingPathComponent("ghostty/config", isDirectory: false)
        try GhosttyConfigBuilder.writeGlobalConfigFile(cfg: cfg, theme: theme, to: configURL)

        // Cheap signature: re-init only if anything we wrote changed.
        let sig = try String(contentsOf: configURL, encoding: .utf8)
        if app == nil || sig != lastConfigSig {
            app = try AlasGhostty.App(configPath: configURL.path)
            lastConfigSig = sig
        }
    }

    /// Create a new session for the given worktree and return it.
    /// `startupScriptSuffix`, when non-empty, is appended to the effective
    /// per-session startup script and runs after the user's normal init —
    /// used by worktree-create's auto-launch-agent path to put the agent
    /// CLI directly into the new terminal session (visible, with a TTY,
    /// not a hidden detached process).
    @discardableResult
    func openSession(
        worktree: Worktree,
        project: ProjectConfig,
        cfg: AppConfig.Terminal,
        theme: Theme,
        forcedCwd: URL? = nil,
        startupScriptSuffix: String? = nil
    ) throws -> TerminalSession {
        try ensureApp(cfg: cfg, theme: theme)
        guard let app else { throw NSError(domain: "TerminalService", code: 1) }

        let sessionId = UUID().uuidString
        var env = EnvBuilder.build(
            project: project, worktree: worktree, sessionId: sessionId,
            socketPath: socketPath, inheritParent: cfg.inheritParentEnv
        )
        let baseScript = StartupScriptResolver.sessionOpenScript(
            global: cfg,
            project: project
        )
        let effectiveScript = TerminalCLIInjection.compose(
            shell: cfg.shell,
            userStartupScript: baseScript,
            startupScriptSuffix: startupScriptSuffix
        )
        let plan = try StartupScriptInstaller.plan(
            shell: cfg.shell,
            startupScript: effectiveScript,
            sessionId: sessionId
        )
        // Plan-supplied env overrides (e.g. ZDOTDIR for zsh startup scripts)
        // win over inherited env.
        for (k, v) in plan.envOverrides { env[k] = v }
        let cwd = forcedCwd ?? resolveWorkingDirectory(
            preference: cfg.workingDirectory,
            worktree: worktree,
            project: project
        )
        let surfaceConfig = GhosttyConfigBuilder.makeSurfaceConfiguration(
            cwd: cwd,
            env: env,
            executable: plan.executable,
            args: plan.args
        )
        let surface = AlasGhostty.SurfaceView(
            app: app,
            configuration: surfaceConfig
        )
        let session = TerminalSession(
            id: sessionId,
            worktreeId: worktree.id,
            projectId: project.id,
            surface: surface,
            executable: plan.executable,
            args: plan.args
        )
        registry.register(session)
        return session
    }

    func closeSession(id: String) {
        if let s = registry.session(for: id) {
            s.surface.removeFromSuperview()
        }
        registry.unregister(id: id)
    }

    /// Resolve the per-session cwd from the user's preference. v1 supports
    /// `worktreeRoot` (default) and `repoRoot`; "lastUsed" was a previously-
    /// exposed option that always silently fell through to worktreeRoot, so
    /// it was dropped from the settings UI. It'll return when we actually
    /// persist per-session cwd.
    private func resolveWorkingDirectory(
        preference: String,
        worktree: Worktree,
        project: ProjectConfig
    ) -> URL {
        switch preference {
        case "repoRoot":
            return URL(fileURLWithPath: project.path)
        default:
            return worktree.path
        }
    }
}
