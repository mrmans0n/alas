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

    /// Per-session socket path provider. Given a leaf id, returns the
    /// value to set as `ALAS_SOCKET_PATH` in the spawned shell's env, or
    /// nil if no harness socket is available. AppState wires this to
    /// `AgentHookSocketServer.linkSession(leafId:)`, which produces a
    /// stable per-leaf symlink so the env var stays valid across Alas
    /// relaunches. Per-leaf scoping avoids the multi-instance collision a
    /// single shared symlink would have.
    @ObservationIgnored var socketPathProvider: ((String) -> String?)?
    /// Called when a session is closed so the provider can release any
    /// per-session state (e.g. unlink the symlink).
    @ObservationIgnored var socketReleaseHandler: ((String) -> Void)?
    @ObservationIgnored let zmxClient: ZmxClient

    /// Default initializer used by production code paths (AppState).
    init(zmxClient: ZmxClient = ZmxClient(env: ZmxEnv.resolve())) {
        self.zmxClient = zmxClient
    }

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
        startupScriptSuffix: String? = nil,
        leafId: String = UUID().uuidString
    ) throws -> TerminalSession {
        try ensureApp(cfg: cfg, theme: theme)
        guard let app else { throw NSError(domain: "TerminalService", code: 1) }

        let sessionId = leafId
        // Per-session socket path: AppState wires `socketPathProvider` to
        // `AgentHookSocketServer.linkSession(leafId:)`, which (re)creates
        // a per-leaf symlink. The same symlink path stays valid across
        // Alas restarts, so zmx-persisted shells keep delivering hooks
        // to the live socket on the next launch.
        let perSessionSocket = socketPathProvider?(sessionId)
        var env = EnvBuilder.build(
            project: project, worktree: worktree, sessionId: sessionId,
            socketPath: perSessionSocket, inheritParent: cfg.inheritParentEnv,
            zmxDir: zmxClient.env.zmxDir?.path
        )
        if perSessionSocket != nil {
            let binDir = try TerminalCLIInjection.installExecutables()
            env["PATH"] = TerminalCLIInjection.pathValue(
                prepending: binDir.path,
                to: env["PATH"]
            )
        }
        let baseScript = StartupScriptResolver.sessionOpenScript(
            global: cfg,
            project: project
        )
        let effectiveScript = Self.composeStartupScript(
            userStartupScript: baseScript,
            startupScriptSuffix: startupScriptSuffix
        )
        let innerPlan = try StartupScriptInstaller.plan(
            shell: cfg.shell,
            startupScript: effectiveScript,
            sessionId: sessionId
        )
        let zmxSessionName = ZmxSessionName.derive(worktreeId: worktree.id, leafId: sessionId)
        let plan = TerminalService.resolveLaunchPlan(
            keepAlive: cfg.keepSessionsAlive,
            zmxClient: zmxClient,
            sessionName: zmxSessionName,
            innerPlan: innerPlan
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

    func closeSession(id: String, worktreeId explicitWorktreeId: String? = nil) {
        let existing = registry.session(for: id)
        if let s = existing {
            s.surface.removeFromSuperview()
        }
        registry.unregister(id: id)
        // `zmxClient.killSession` blocks up to ~5s on a hung daemon. We're
        // on @MainActor here, so dispatch it off-main as fire-and-forget
        // (the call is documented best-effort; we don't read the result).
        if let worktreeId = explicitWorktreeId ?? existing?.worktreeId {
            let client = zmxClient
            let sessionName = ZmxSessionName.derive(worktreeId: worktreeId, leafId: id)
            Task.detached { client.killSession(name: sessionName) }
        }
        socketReleaseHandler?(id)
        cleanupRcfile(sessionId: id)
    }

    /// Called on normal app quit. The zmx attach client process dies with
    /// AppKit's surface tear-down; the daemon-side session keeps running.
    /// No explicit zmx interaction is required — this exists as a named hook
    /// in case future surfaces need post-quit cleanup work.
    func detachAll() {
        // Intentionally empty in v1.
    }

    /// User-requested "Terminate All Terminal Sessions". Kills every
    /// session we currently know about, including persisted-but-unrestored
    /// sessions the caller hands in via `additionalSessions`. Best-effort:
    /// each kill swallows its own errors.
    ///
    /// We deliberately do NOT enumerate `zmx ls` and kill arbitrary
    /// `alas-*` orphans: two Alas processes can share the same `ZMX_DIR`
    /// and we must not kill another live instance's sessions. The
    /// trade-off is that sessions from a true crash (where the pane's
    /// leaf record was also lost) leak; the user can clear those with
    /// `zmx kill` directly.
    ///
    /// `ZmxClient.killSession` blocks up to ~5s, so we run the sweep on
    /// `Task.detached` to keep the MainActor (UI) responsive.
    func terminateAll(additionalSessions: [TerminalSessionIdentity] = []) {
        let live = registry.all.map {
            TerminalSessionIdentity(worktreeId: $0.worktreeId, leafId: $0.id)
        }
        let allSessions = Set(live).union(additionalSessions)
        let client = zmxClient
        Task.detached {
            for session in allSessions {
                client.killSession(name: ZmxSessionName.derive(
                    worktreeId: session.worktreeId,
                    leafId: session.leafId
                ))
            }
        }
    }

    /// Best-effort removal of the per-session rcfile artifacts written by
    /// `StartupScriptInstaller`. Either layout may exist depending on the
    /// shell used at launch:
    ///   - zsh: `<appSupport>/rcfiles/<sessionId>/` (a directory)
    ///   - bash: `<appSupport>/rcfiles/<sessionId>.bashrc` (a file)
    private func cleanupRcfile(sessionId: String) {
        let dir = Paths.appSupportRoot.appendingPathComponent("rcfiles", isDirectory: true)
        let zshDir = dir.appendingPathComponent(sessionId, isDirectory: true)
        let bashFile = dir.appendingPathComponent("\(sessionId).bashrc")
        try? FileManager.default.removeItem(at: zshDir)
        try? FileManager.default.removeItem(at: bashFile)
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

    /// Decide which launch plan to use for a new pane. When
    /// `keepAlive` is true and zmx is available, the inner plan is wrapped
    /// in `zmx attach <name>` so the shell survives app quit. When
    /// `keepAlive` is false, the inner plan is returned unchanged — pre-#317
    /// behavior. When zmx is unavailable, `ZmxClient.wrap` returns the inner
    /// plan unchanged regardless of `keepAlive`.
    ///
    /// Static so tests can drive it without spinning up `Ghostty.App`.
    static func resolveLaunchPlan(
        keepAlive: Bool,
        zmxClient: ZmxClient,
        sessionName: String,
        innerPlan: StartupScriptInstaller.Plan
    ) -> StartupScriptInstaller.Plan {
        guard keepAlive else { return innerPlan }
        return zmxClient.wrap(
            sessionName: sessionName,
            plan: innerPlan
        )
    }

    private static func composeStartupScript(
        userStartupScript: String,
        startupScriptSuffix: String?
    ) -> String {
        [userStartupScript, startupScriptSuffix]
            .compactMap { part in
                let trimmed = part?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n")
    }
}
