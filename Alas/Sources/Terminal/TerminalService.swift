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
    /// Fires when the shell process inside a session exits, as reported by
    /// Ghostty's `close_surface_cb`. `processAlive == false` is the dismiss
    /// signal (shell is gone — or a Ghostty action requested teardown);
    /// `processAlive == true` means a manual-close path is already in flight
    /// and the receiver should no-op. Always invoked on the main thread.
    @ObservationIgnored var onSessionProcessExited: ((_ leafId: String, _ worktreeId: String, _ processAlive: Bool) -> Void)?
    @ObservationIgnored let zmxClient: ZmxClient

    /// In-flight zmx kill tasks. Tracked so `waitForPendingKills` can drain
    /// them at app quit instead of dropping them on the floor when the
    /// process exits. Tasks insert themselves on dispatch and self-remove on
    /// completion via a MainActor follow-up Task.
    @ObservationIgnored private var pendingKillTasks: Set<Task<Void, Never>> = []

    /// Default initializer used by production code paths (AppState).
    init(zmxClient: ZmxClient = ZmxClient(env: ZmxEnv.resolve())) {
        self.zmxClient = zmxClient
    }

    /// Spawn a detached zmx-related task (kill, ls+kill, sweep) and track it
    /// so `waitForPendingKills` can drain on quit. Replaces the bare
    /// `Task.detached { … }` callers used pre-tracking.
    private func dispatchTrackedKill(_ body: @escaping @Sendable () -> Void) {
        let task = Task.detached(operation: body)
        pendingKillTasks.insert(task)
        Task { @MainActor [weak self] in
            _ = await task.value
            self?.pendingKillTasks.remove(task)
        }
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
    /// Auth-only terminals can set `includeUserStartupScript` false so a
    /// long-running session-open script does not block the login command.
    @discardableResult
    func openSession(
        worktree: Worktree,
        project: ProjectConfig,
        cfg: AppConfig.Terminal,
        theme: Theme,
        forcedCwd: URL? = nil,
        startupScriptSuffix: String? = nil,
        includeUserStartupScript: Bool = true,
        environmentOverrides: [String: String] = [:],
        environmentRemovals: Set<String> = [],
        leafId: String = UUID().uuidString,
        allowLegacyAttach: Bool = false,
        preResolvedZmxSessionName: String? = nil
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
        for key in environmentRemovals {
            env.removeValue(forKey: key)
        }
        for (key, value) in environmentOverrides {
            env[key] = value
        }
        if perSessionSocket != nil {
            let binDir = try TerminalCLIInjection.installExecutables()
            env["PATH"] = TerminalCLIInjection.pathValue(
                prepending: binDir.path,
                to: env["PATH"]
            )
        }
        let baseScript = includeUserStartupScript
            ? StartupScriptResolver.sessionOpenScript(global: cfg, project: project)
            : ""
        let effectiveScript = Self.composeStartupScript(
            userStartupScript: baseScript,
            startupScriptSuffix: startupScriptSuffix
        )
        let innerPlan = try StartupScriptInstaller.plan(
            shell: cfg.shell,
            startupScript: effectiveScript,
            sessionId: sessionId
        )
        let zmxSessionName = preResolvedZmxSessionName ?? sessionNameForAttach(
            worktree: worktree,
            project: project,
            leafId: sessionId,
            allowLegacy: allowLegacyAttach
        )
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
        let capturedLeafId = sessionId
        let capturedWorktreeId = worktree.id
        surface.processExitHandler = { [weak self] processAlive in
            self?.onSessionProcessExited?(capturedLeafId, capturedWorktreeId, processAlive)
        }
        let session = TerminalSession(
            id: sessionId,
            worktreeId: worktree.id,
            projectId: project.id,
            surface: surface,
            executable: plan.executable,
            args: plan.args,
            zmxSessionName: (cfg.keepSessionsAlive && zmxClient.isAvailable) ? zmxSessionName : nil
        )
        registry.register(session)
        return session
    }

    func closeSession(
        id: String,
        worktreeId explicitWorktreeId: String? = nil,
        projectPath: String? = nil
    ) {
        let existing = registry.session(for: id)
        if let s = existing {
            s.surface.removeFromSuperview()
        }
        registry.unregister(id: id)
        // `zmxClient.killSession` blocks up to ~5s on a hung daemon. We're
        // on @MainActor here, so dispatch it off-main, tracked so
        // `waitForPendingKills` can drain it before the app exits —
        // otherwise a quick close+Cmd-Q race would leak the daemon-side
        // session, and the next launch would carry forward the orphan.
        if let existingName = existing?.zmxSessionName {
            let client = zmxClient
            dispatchTrackedKill { client.killSession(name: existingName) }
        } else if let worktreeId = explicitWorktreeId ?? existing?.worktreeId {
            let client = zmxClient
            dispatchTrackedKill {
                let sessionNames = Self.sessionNamesForCleanup(
                    worktreeId: worktreeId,
                    projectPath: projectPath,
                    leafId: id,
                    zmxClient: client
                )
                for sessionName in sessionNames {
                    client.killSession(name: sessionName)
                }
            }
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
        let liveNames = registry.all.map {
            $0.zmxSessionName ?? ZmxSessionName.derive(worktreeId: $0.worktreeId, leafId: $0.id)
        }
        let client = zmxClient
        dispatchTrackedKill {
            var allNames = Set(liveNames)
            for session in additionalSessions {
                allNames.formUnion(Self.sessionNamesForCleanup(
                    worktreeId: session.worktreeId,
                    projectPath: session.projectPath,
                    leafId: session.leafId,
                    zmxClient: client
                ))
            }
            for name in allNames {
                client.killSession(name: name)
            }
        }
    }

    /// Self-heal at boot. Enumerates `zmx ls`, then kills every scoped
    /// `alas-<wtHash>-<leafHash>` session whose `wtHash` matches one of
    /// `knownWorktreeIds` but whose `leafHash` is absent from
    /// `knownLeafIds`. Multi-instance safe: another Alas process under the
    /// same `ZMX_DIR` has its own (different) worktree ids, so its
    /// `wtHash` won't be in our set and its sessions stay untouched.
    /// Legacy `alas-<leafId>` shapes are skipped — the existing close-path
    /// cleanup already handles those when the matching tab is closed.
    ///
    /// `ZMX_SESSION_PREFIX` is read from the current environment and applied
    /// to ls-output stripping + kill-argument bare names, mirroring how the
    /// rest of `ZmxClient` keeps the prefix transparent: zmx's CLI prepends
    /// the env-set prefix on both create and kill, so we feed it the bare
    /// `alas-…` name on either side.
    func sweepOrphans(knownWorktreeIds: Set<String>, knownLeafIds: Set<String>) {
        let wtHashes = Set(knownWorktreeIds.map(ZmxSessionName.hash16))
        let leafHashes = Set(knownLeafIds.map(ZmxSessionName.hash16))
        let prefix = ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? ""
        let client = zmxClient
        dispatchTrackedKill {
            let names = client.listSessions()
            let orphans = Self.orphanSessionNames(
                allSessionNames: names,
                knownWorktreeIdHashes: wtHashes,
                knownLeafIdHashes: leafHashes,
                sessionPrefix: prefix
            )
            for name in orphans {
                client.killSession(name: name)
            }
        }
    }

    /// Snapshot of the currently-open zmx sessions for the Settings ›
    /// Terminal "Open sessions" list. Runs `zmx ls` off-main (it blocks up
    /// to ~5s), then classifies the result against this window's registry.
    func loadOpenSessions() async -> OpenSessionsSnapshot {
        guard zmxClient.isAvailable else { return .empty }
        let prefix = ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? ""
        let tracked = registry.all.map {
            TrackedSessionRef(leafId: $0.id, worktreeId: $0.worktreeId, zmxSessionName: $0.zmxSessionName)
        }
        let client = zmxClient
        let infos = await Task.detached { client.listSessionInfos() }.value
        return OpenSessionsClassifier.classify(infos: infos, tracked: tracked, sessionPrefix: prefix)
    }

    /// Kill a single orphaned session by its bare name. `ZmxClient.killSession`
    /// re-prepends `ZMX_SESSION_PREFIX` itself, matching the create/kill
    /// symmetry used everywhere else. Dispatched off-main and tracked so a
    /// hung daemon never blocks the UI and `waitForPendingKills` can drain it.
    func killOrphanSession(name: String) {
        let client = zmxClient
        dispatchTrackedKill { client.killSession(name: name) }
    }

    /// Kill every idle (`clients == 0`) orphan in `snapshot` — the
    /// "grown wild" cleanup. Active and in-use rows are left untouched.
    func killIdleOrphans(_ snapshot: OpenSessionsSnapshot) {
        let names = snapshot.orphaned.filter(\.isIdle).map(\.name)
        guard !names.isEmpty else { return }
        let client = zmxClient
        dispatchTrackedKill {
            for name in names { client.killSession(name: name) }
        }
    }

    /// Pure filter exposed for tests: pick the scoped `alas-*` sessions
    /// belonging to one of our worktrees that no known leaf claims.
    /// Returns bare (unprefixed) names so callers can pass them straight to
    /// `ZmxClient.killSession`, which lets the CLI re-prepend
    /// `ZMX_SESSION_PREFIX` itself — matching the create/kill symmetry in
    /// `ZmxClient.wrap` / `killSession`.
    nonisolated static func orphanSessionNames(
        allSessionNames: [String],
        knownWorktreeIdHashes: Set<String>,
        knownLeafIdHashes: Set<String>,
        sessionPrefix: String = ""
    ) -> [String] {
        allSessionNames.compactMap { rawName in
            // With a prefix set, ignore names that don't carry it — those
            // belong to a different tool or a stale unprefixed run, and
            // re-killing them with the prefix re-applied could hit the wrong
            // session.
            guard rawName.hasPrefix(sessionPrefix) else { return nil }
            let bareName = String(rawName.dropFirst(sessionPrefix.count))
            guard let parsed = ZmxSessionName.parseScoped(bareName),
                  knownWorktreeIdHashes.contains(parsed.worktreeIdHash),
                  !knownLeafIdHashes.contains(parsed.leafIdHash)
            else { return nil }
            return bareName
        }
    }

    /// Block the caller for up to `timeout` while in-flight zmx kills
    /// complete. Called from `applicationWillTerminate` so a Cmd-Q
    /// immediately after a tab close still flushes the kill subprocess
    /// to the daemon before Alas exits (the subprocess would otherwise
    /// die with us, leaving an orphan that next launch couldn't easily
    /// trace back). Uses a semaphore from a background-thread awaiter
    /// rather than blocking the @MainActor Task's executor, so the
    /// follow-up `pendingKillTasks.remove` MainActor work can still
    /// schedule.
    func waitForPendingKills(timeout: TimeInterval) {
        let tasks = pendingKillTasks
        guard !tasks.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for task in tasks {
                    group.addTask { await task.value }
                }
                for await _ in group {}
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
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

    private func sessionNameForAttach(
        worktree: Worktree,
        project: ProjectConfig,
        leafId: String,
        allowLegacy: Bool
    ) -> String {
        let scoped = ZmxSessionName.derive(worktreeId: worktree.id, leafId: leafId)
        guard allowLegacy else { return scoped }
        return Self.resolveSessionNameForAttach(
            worktreeId: worktree.id,
            projectPath: project.path,
            leafId: leafId,
            allowLegacy: allowLegacy,
            legacySessionInfos: zmxClient.listSessionInfos()
        )
    }

    nonisolated private static func sessionNamesForCleanup(
        worktreeId: String,
        projectPath: String?,
        leafId: String,
        zmxClient: ZmxClient
    ) -> [String] {
        let scoped = ZmxSessionName.derive(worktreeId: worktreeId, leafId: leafId)
        let legacy = ZmxSessionName.legacy(leafId: leafId)
        let roots = [worktreeId] + (projectPath.map { [$0] } ?? [])
        guard legacySessionBelongsToKnownRoot(legacy, roots: roots, zmxClient: zmxClient) else {
            return [scoped]
        }
        return [scoped, legacy]
    }

    nonisolated static func resolveSessionNameForAttach(
        worktreeId: String,
        projectPath: String,
        leafId: String,
        allowLegacy: Bool,
        legacySessionInfos: [ZmxSessionInfo]
    ) -> String {
        let scoped = ZmxSessionName.derive(worktreeId: worktreeId, leafId: leafId)
        guard allowLegacy else { return scoped }
        let legacy = ZmxSessionName.legacy(leafId: leafId)
        guard legacySessionBelongsToKnownRoot(
            legacy,
            roots: [worktreeId, projectPath],
            sessionInfos: legacySessionInfos
        ) else {
            return scoped
        }
        return legacy
    }

    nonisolated static func legacySessionBelongsToKnownRoot(
        _ name: String,
        roots: [String],
        zmxClient: ZmxClient
    ) -> Bool {
        legacySessionBelongsToKnownRoot(
            name,
            roots: roots,
            sessionInfos: zmxClient.listSessionInfos()
        )
    }

    nonisolated static func legacySessionBelongsToKnownRoot(
        _ name: String,
        roots: [String],
        sessionInfos: [ZmxSessionInfo]
    ) -> Bool {
        let roots = Set(roots.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return sessionInfos.contains { info in
            info.name == name && startDir(info.startDir, belongsToAnyOf: roots)
        }
    }

    nonisolated private static func startDir(_ startDir: String?, belongsToAnyOf roots: Set<String>) -> Bool {
        guard let startDir else { return false }
        let start = URL(fileURLWithPath: startDir).standardizedFileURL.path
        return roots.contains { root in
            start == root || start.hasPrefix(root + "/")
        }
    }
}
