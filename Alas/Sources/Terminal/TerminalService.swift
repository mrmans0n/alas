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
    @ObservationIgnored var onSessionProcessExited: ((_ leafId: String, _ owner: SessionOwnerID, _ processAlive: Bool) -> Void)?
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

    struct CheckoutLaunchContext: Equatable {
        let owner: SessionOwnerID
        let cwd: URL
        let environment: [String: String]
        let startupScript: String
    }

    /// Builds the narrow, repository-independent context for a shared
    /// checkout terminal. Kept separate from `EnvBuilder` because the latter
    /// is the compatibility contract for existing Worktree sessions.
    nonisolated static func checkoutLaunchContext(
        context: WorkspaceTerminalContext,
        leafID: String
    ) -> CheckoutLaunchContext {
        CheckoutLaunchContext(
            owner: context.owner,
            cwd: URL(fileURLWithPath: context.rootPath),
            environment: [
                "ALAS_WORKSPACE_CHECKOUT_ID": context.checkoutID.uuidString.lowercased(),
                "ALAS_WORKSPACE_CHECKOUT_ROOT": context.rootPath,
                "ALAS_WORKSPACE_BRANCH": context.branch,
                "ALAS_WORKSPACE_MANIFEST": context.manifestPath,
            ],
            startupScript: context.startupScript
        )
    }

    nonisolated static func checkoutLocalEnvironment(
        context: WorkspaceTerminalContext,
        leafID: String,
        inheritParent: Bool,
        parent: [String: String] = ProcessInfo.processInfo.environment,
        socketPath: String?,
        zmxDir: String?,
        cliInstaller: () throws -> URL = { try TerminalCLIInjection.installExecutables() }
    ) throws -> [String: String] {
        var env: [String: String] = inheritParent
            ? parent.filter { !$0.key.hasPrefix("ALAS_") }
            : [:]
        env.merge(checkoutLaunchContext(context: context, leafID: leafID).environment) { _, checkoutValue in checkoutValue }
        env["ALAS_SESSION_ID"] = leafID
        env["ZMX_SESSION"] = ""
        if let zmxDir { env["ZMX_DIR"] = zmxDir }
        if let socketPath {
            env["ALAS_SOCKET_PATH"] = socketPath
            let binDir = try cliInstaller()
            env["PATH"] = TerminalCLIInjection.pathValue(
                prepending: binDir.path,
                to: env["PATH"]
            )
        }
        return env
    }

    /// A persisted checkout cwd is accepted only when it came from the same
    /// execution location and remains inside the frozen checkout root.
    nonisolated static func checkoutRestorationCwd(
        savedPath: String?,
        context: WorkspaceTerminalContext,
        savedLocation: ExecutionLocation? = nil
    ) -> URL? {
        guard savedLocation?.normalized == context.executionLocation,
              let savedPath,
              !savedPath.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: context.rootPath).standardizedFileURL.path
        let candidate = URL(fileURLWithPath: savedPath).standardizedFileURL.path
        guard candidate == root || candidate.hasPrefix(root + "/") else { return nil }
        return URL(fileURLWithPath: candidate)
    }

    nonisolated static func checkoutWorkingDirectory(
        forcedCwd: URL?,
        forcedCwdLocation: ExecutionLocation?,
        context: WorkspaceTerminalContext
    ) -> URL? {
        checkoutRestorationCwd(
            savedPath: forcedCwd?.path,
            context: context,
            savedLocation: forcedCwdLocation
        )
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

    private func dispatchTrackedKill(_ body: @escaping @Sendable () async -> Void) {
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

    /// Create a short-lived terminal surface that is not registered as a
    /// project session. First-contact SSH uses this to render OpenSSH's native
    /// host-key, password, keyboard-interactive, and hardware-key prompts.
    func makeTransientSurface(
        cfg: AppConfig.Terminal,
        theme: Theme,
        executable: String,
        args: [String],
        onExit: @escaping () -> Void
    ) throws -> AlasGhostty.SurfaceView {
        try ensureApp(cfg: cfg, theme: theme)
        guard let app else { throw NSError(domain: "TerminalService", code: 1) }

        let surfaceConfig = GhosttyConfigBuilder.makeSurfaceConfiguration(
            cwd: FileManager.default.homeDirectoryForCurrentUser,
            env: ProcessInfo.processInfo.environment,
            executable: executable,
            args: args
        )
        let surface = AlasGhostty.SurfaceView(app: app, configuration: surfaceConfig)
        surface.processExitHandler = { processAlive in
            guard !processAlive else { return }
            onExit()
        }
        return surface
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
        let remoteHost = project.host
        // Per-session socket path: AppState wires `socketPathProvider` to
        // `AgentHookSocketServer.linkSession(leafId:)`, which (re)creates
        // a per-leaf symlink. The same symlink path stays valid across
        // Alas restarts, so zmx-persisted shells keep delivering hooks
        // to the live socket on the next launch.
        let perSessionSocket = remoteHost == nil ? socketPathProvider?(sessionId) : nil
        var env = EnvBuilder.build(
            project: project, worktree: worktree, sessionId: sessionId,
            socketPath: perSessionSocket, inheritParent: cfg.inheritParentEnv,
            zmxDir: remoteHost == nil ? zmxClient.env.zmxDir?.path : nil
        )
        for key in environmentRemovals {
            env.removeValue(forKey: key)
        }
        for (key, value) in environmentOverrides {
            env[key] = value
        }
        if remoteHost != nil {
            env = env.filter { !$0.key.hasPrefix("ALAS_") }
            env.removeValue(forKey: "ZMX_DIR")
        }
        if remoteHost == nil, perSessionSocket != nil {
            let binDir = try TerminalCLIInjection.installExecutables()
            env["PATH"] = TerminalCLIInjection.pathValue(
                prepending: binDir.path,
                to: env["PATH"]
            )
        }
        let effectiveScript = Self.effectiveStartupScript(
            global: cfg,
            project: project,
            includeUserStartupScript: includeUserStartupScript,
            startupScriptSuffix: startupScriptSuffix
        )
        let zmxSessionName = preResolvedZmxSessionName ?? sessionNameForAttach(
            worktree: worktree,
            project: project,
            leafId: sessionId,
            allowLegacy: allowLegacyAttach
        )
        let executable: String
        let args: [String]
        let envOverrides: [String: String]
        if let remoteHost {
            let remoteCwd = forcedCwd?.path ?? worktree.path.path
            let launch = Self.remoteLaunch(
                host: remoteHost,
                worktreePath: remoteCwd,
                zmxSessionName: zmxSessionName,
                keepAlive: cfg.keepSessionsAlive,
                startupSuffix: effectiveScript.isEmpty ? nil : effectiveScript
            )
            executable = launch.executable
            args = launch.args
            envOverrides = [:]
        } else {
            let innerPlan = try StartupScriptInstaller.plan(shell: cfg.shell, startupScript: effectiveScript, sessionId: sessionId)
            let plan = TerminalService.resolveLaunchPlan(keepAlive: cfg.keepSessionsAlive, zmxClient: zmxClient, sessionName: zmxSessionName, innerPlan: innerPlan)
            executable = plan.executable
            args = plan.args
            envOverrides = plan.envOverrides
        }
        // Plan-supplied env overrides (e.g. ZDOTDIR for zsh startup scripts)
        // win over inherited env.
        for (k, v) in envOverrides { env[k] = v }
        let cwd = remoteHost == nil ? (forcedCwd ?? resolveWorkingDirectory(
            preference: cfg.workingDirectory,
            worktree: worktree,
            project: project
        )) : FileManager.default.homeDirectoryForCurrentUser
        let surfaceConfig = GhosttyConfigBuilder.makeSurfaceConfiguration(
            cwd: cwd,
            env: env,
            executable: executable,
            args: args
        )
        let surface = AlasGhostty.SurfaceView(
            app: app,
            configuration: surfaceConfig
        )
        let capturedLeafId = sessionId
        let capturedWorktreeId = worktree.id
        surface.processExitHandler = { [weak self] processAlive in
            self?.onSessionProcessExited?(capturedLeafId, .worktree(capturedWorktreeId), processAlive)
        }
        let session = TerminalSession(
            id: sessionId,
            worktreeId: worktree.id,
            projectId: project.id,
            surface: surface,
            executable: executable,
            args: args,
            zmxSessionName: cfg.keepSessionsAlive && (remoteHost != nil || zmxClient.isAvailable) ? zmxSessionName : nil,
            remoteHost: remoteHost
        )
        registry.register(session)
        return session
    }

    /// Opens a shared terminal owned by a frozen Workspace Checkout. Unlike
    /// the worktree overload, this path never reads a focused repository or
    /// emits repository-specific environment values.
    @discardableResult
    func openCheckoutSession(
        context: WorkspaceTerminalContext,
        cfg: AppConfig.Terminal,
        theme: Theme,
        forcedCwd: URL? = nil,
        forcedCwdLocation: ExecutionLocation? = nil,
        leafId: String = UUID().uuidString
    ) throws -> TerminalSession {
        try ensureApp(cfg: cfg, theme: theme)
        guard let app else { throw NSError(domain: "TerminalService", code: 1) }

        let launchContext = Self.checkoutLaunchContext(context: context, leafID: leafId)
        let remoteHost: String? = {
            if case .ssh(let host) = context.executionLocation { return host }
            return nil
        }()
        var env: [String: String]
        if remoteHost == nil {
            env = try Self.checkoutLocalEnvironment(
                context: context,
                leafID: leafId,
                inheritParent: cfg.inheritParentEnv,
                socketPath: socketPathProvider?(leafId),
                zmxDir: zmxClient.env.zmxDir?.path
            )
        } else {
            var remoteEnv: [String: String] = cfg.inheritParentEnv
                ? ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ALAS_") }
                : [:]
            remoteEnv.merge(launchContext.environment) { _, checkoutValue in checkoutValue }
            env = remoteEnv
        }

        let sessionName = ZmxSessionName.derive(owner: context.owner, leafId: leafId)
        let executable: String
        let args: [String]
        if let remoteHost {
            let acceptedCwd = Self.checkoutWorkingDirectory(
                forcedCwd: forcedCwd,
                forcedCwdLocation: forcedCwdLocation,
                context: context
            )
            let launch = Self.remoteLaunch(
                host: remoteHost,
                worktreePath: acceptedCwd?.path ?? context.rootPath,
                zmxSessionName: sessionName,
                keepAlive: cfg.keepSessionsAlive,
                startupSuffix: context.startupScript.isEmpty ? nil : context.startupScript,
                environment: launchContext.environment
            )
            executable = launch.executable
            args = launch.args
        } else {
            let startup = try StartupScriptInstaller.plan(
                shell: cfg.shell,
                startupScript: context.startupScript,
                sessionId: leafId
            )
            let plan = Self.resolveLaunchPlan(
                keepAlive: cfg.keepSessionsAlive,
                zmxClient: zmxClient,
                sessionName: sessionName,
                innerPlan: startup
            )
            executable = plan.executable
            args = plan.args
            for (key, value) in plan.envOverrides { env[key] = value }
        }
        let acceptedCwd = Self.checkoutWorkingDirectory(forcedCwd: forcedCwd, forcedCwdLocation: forcedCwdLocation, context: context)
        let cwd = remoteHost == nil
            ? (acceptedCwd ?? URL(fileURLWithPath: context.rootPath))
            : FileManager.default.homeDirectoryForCurrentUser
        let surface = AlasGhostty.SurfaceView(
            app: app,
            configuration: GhosttyConfigBuilder.makeSurfaceConfiguration(
                cwd: cwd, env: env, executable: executable, args: args
            )
        )
        let capturedOwner = context.owner
        surface.processExitHandler = { [weak self] processAlive in
            self?.onSessionProcessExited?(leafId, capturedOwner, processAlive)
        }
        let session = TerminalSession(
            id: leafId,
            owner: context.owner,
            surface: surface,
            executable: executable,
            args: args,
            zmxSessionName: cfg.keepSessionsAlive && (remoteHost != nil || zmxClient.isAvailable) ? sessionName : nil,
            remoteHost: remoteHost
        )
        registry.register(session)
        return session
    }

    /// Archive and other checkout lifecycle operations stop only sessions
    /// owned by that exact checkout ID. The execution location is part of the
    /// owner, preventing a local archive from touching an SSH checkout.
    func stopSessions(owner: SessionOwnerID) {
        for session in registry.all where session.owner == owner {
            closeSession(id: session.id)
        }
    }

    nonisolated static func remoteLaunch(host: String, worktreePath: String, zmxSessionName: String, keepAlive: Bool, startupSuffix: String?, environment: [String: String] = [:]) -> (executable: String, args: [String]) {
        let script = RemoteTerminalScript.attachScript(worktreePath: worktreePath, sessionName: zmxSessionName, useZmx: keepAlive, startupSuffix: startupSuffix, environment: environment)
        let invocation = RemoteTerminalScript.surfaceInvocation(host: host, script: script)
        return (invocation.executable, invocation.args)
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
        if let host = existing?.remoteHost, let existingName = existing?.zmxSessionName {
            dispatchTrackedKill { await Self.killRemoteSession(host: host, name: existingName) }
        } else if let existingName = existing?.zmxSessionName {
            let client = zmxClient
            dispatchTrackedKill { client.killSession(name: existingName) }
        } else if let worktreeId = explicitWorktreeId ?? existing?.worktreeId {
            let client = zmxClient
            let remoteHost = Self.remoteHostForCleanup(worktreeId: worktreeId, projectPath: projectPath)
            dispatchTrackedKill {
                let sessionNames = Self.sessionNamesForCleanup(
                    worktreeId: worktreeId,
                    projectPath: projectPath,
                    leafId: id,
                    zmxClient: client
                )
                for sessionName in sessionNames {
                    if let remoteHost {
                        await Self.killRemoteSession(host: remoteHost, name: sessionName)
                    } else {
                        client.killSession(name: sessionName)
                    }
                }
            }
        }
        socketReleaseHandler?(id)
        cleanupRcfile(sessionId: id)
    }

    /// Checkout cleanup has no Project/worktree fallback: its typed owner is
    /// sufficient to derive the exact scoped zmx name and SSH destination.
    func closeSession(id: String, owner: SessionOwnerID) {
        if let existing = registry.session(for: id) {
            closeSession(id: id)
            return
        }
        let name = ZmxSessionName.derive(owner: owner, leafId: id)
        switch owner {
        case .worktree(let worktreeID):
            closeSession(id: id, worktreeId: worktreeID)
            return
        case .workspaceCheckout(_, let location):
            switch location.normalized {
            case .local:
                let client = zmxClient
                dispatchTrackedKill { client.killSession(name: name) }
            case .ssh(let host):
                dispatchTrackedKill { await Self.killRemoteSession(host: host, name: name) }
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
        var localNames = Set<String>()
        var remoteNamesByHost: [String: Set<String>] = [:]
        for session in registry.all {
            let name = session.zmxSessionName ?? ZmxSessionName.derive(worktreeId: session.worktreeId, leafId: session.id)
            if let host = session.remoteHost {
                remoteNamesByHost[host, default: []].insert(name)
            } else {
                localNames.insert(name)
            }
        }
        let client = zmxClient
        for session in additionalSessions {
            let scoped = session.zmxSessionName
            if let host = Self.remoteHostForCleanup(session: session) {
                remoteNamesByHost[host, default: []].insert(scoped)
            } else {
                localNames.insert(scoped)
            }
        }
        dispatchTrackedKill {
            for name in localNames {
                client.killSession(name: name)
            }
            let localAdditionalSessions = additionalSessions.filter {
                Self.remoteHostForCleanup(session: $0) == nil
            }
            let localLegacySessionInfos = localAdditionalSessions.isEmpty ? [] : client.listSessionInfos()
            for session in localAdditionalSessions {
                let scoped = session.zmxSessionName
                let legacyNames = Self.sessionNamesForCleanup(
                    worktreeId: session.worktreeId,
                    projectPath: session.projectPath,
                    leafId: session.leafId,
                    legacySessionInfos: localLegacySessionInfos
                ).filter { $0 != scoped }
                guard !legacyNames.isEmpty else { continue }
                for name in legacyNames {
                    client.killSession(name: name)
                }
            }
            for (host, names) in remoteNamesByHost {
                for name in names {
                    await Self.killRemoteSession(host: host, name: name)
                }
            }
            let remoteAdditionalSessionsByHost = Dictionary(grouping: additionalSessions.compactMap { session -> (String, TerminalSessionIdentity)? in
                guard let host = Self.remoteHostForCleanup(session: session) else {
                    return nil
                }
                return (host, session)
            }, by: \.0)
            for (host, pairs) in remoteAdditionalSessionsByHost {
                let remoteSessionInfos = await Self.remoteSessionInfos(host: host)
                for (_, session) in pairs {
                    let scoped = session.zmxSessionName
                    let legacyNames = Self.sessionNamesForCleanup(
                        worktreeId: session.worktreeId,
                        projectPath: session.projectPath,
                        leafId: session.leafId,
                        legacySessionInfos: remoteSessionInfos
                    ).filter { $0 != scoped }
                    for name in legacyNames {
                        await Self.killRemoteSession(host: host, name: name)
                    }
                }
            }
        }
    }

    private nonisolated static func remoteHostForCleanup(session: TerminalSessionIdentity) -> String? {
        switch session.owner {
        case .worktree:
            return remoteHostForCleanup(worktreeId: session.worktreeId, projectPath: session.projectPath)
        case .workspaceCheckout(_, .local):
            return nil
        case .workspaceCheckout(_, .ssh(let host)):
            return host
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

    func sweepWorkspaceCheckoutOrphans(knownLeavesByOwner: [SessionOwnerID: Set<String>]) {
        let prefix = ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? ""
        let client = zmxClient
        dispatchTrackedKill {
            let names = client.listSessions()
            let orphans = Self.orphanWorkspaceSessionNames(
                allSessionNames: names,
                knownLeavesByOwner: knownLeavesByOwner,
                sessionPrefix: prefix
            )
            for name in orphans {
                client.killSession(name: name)
            }
        }
    }

    /// Best-effort remote counterpart to `ZmxClient.killSession`. This is
    /// intentionally batch-mode so closing a pane can never wait for auth.
    nonisolated static func killRemoteSession(host: String, name: String) async {
        _ = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: RemoteTerminalScript.zmxBatchCommand(["kill", name]),
            timeout: 10
        )
    }

    nonisolated static func remoteSessionInfos(host: String) async -> [ZmxSessionInfo] {
        guard let result = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: RemoteTerminalScript.zmxBatchCommand(["ls"]),
            timeout: 10
        ), result.exitCode == 0 else {
            return []
        }
        return ZmxClient.parseSessionInfos(result.stdout)
    }

    nonisolated static func remoteHostForCleanup(worktreeId: String, projectPath: String?) -> String? {
        RemoteHostRegistry.shared.host(forPath: worktreeId)
            ?? RemoteHostRegistry.shared.host(forPath: projectPath)
    }

    /// Find scoped remote sessions with no persisted terminal leaf and remove
    /// them one at a time. Connection failures are ignored; the next boot or
    /// a later successful connection will retry the sweep.
    nonisolated static func sweepRemoteOrphans(
        host: String,
        knownWorktreeIds: Set<String>,
        knownLeafIds: Set<String>
    ) async {
        guard let result = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: RemoteTerminalScript.zmxBatchCommand(["ls", "--short"]),
            timeout: 10
        ), result.exitCode == 0 else {
            return
        }

        let names = result.stdout.split(separator: "\n").map(String.init)
        let orphans = orphanSessionNames(
            allSessionNames: names,
            knownWorktreeIdHashes: Set(knownWorktreeIds.map(ZmxSessionName.hash16)),
            knownLeafIdHashes: Set(knownLeafIds.map(ZmxSessionName.hash16))
        )
        for name in orphans {
            await killRemoteSession(host: host, name: name)
        }
    }

    nonisolated static func sweepRemoteWorkspaceCheckoutOrphans(
        host: String,
        knownLeavesByOwner: [SessionOwnerID: Set<String>]
    ) async {
        let filtered = knownLeavesByOwner.filter { owner, _ in
            guard case .workspaceCheckout(_, .ssh(let destination)) = owner else { return false }
            return destination == host
        }
        guard !filtered.isEmpty,
              let result = try? await RemoteExec.run(
                  host: host,
                  cwd: nil,
                  command: RemoteTerminalScript.zmxBatchCommand(["ls", "--short"]),
                  timeout: 10
              ), result.exitCode == 0 else {
            return
        }

        let names = result.stdout.split(separator: "\n").map(String.init)
        for name in orphanWorkspaceSessionNames(allSessionNames: names, knownLeavesByOwner: filtered) {
            await killRemoteSession(host: host, name: name)
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

    nonisolated static func orphanWorkspaceSessionNames(
        allSessionNames: [String],
        knownLeavesByOwner: [SessionOwnerID: Set<String>],
        sessionPrefix: String = ""
    ) -> [String] {
        let knownNames = Set(knownLeavesByOwner.flatMap { owner, leafIds in
            leafIds.map { ZmxSessionName.derive(owner: owner, leafId: $0) }
        })
        let ownerPrefixes = knownLeavesByOwner.map { owner, _ -> String in
            switch owner {
            case .worktree:
                return ""
            case .workspaceCheckout(let checkoutID, let location):
                return "alas-workspace-\(checkoutID.uuidString.lowercased())-\(ZmxSessionName.hash16(location.normalized.identityComponent))-"
            }
        }.filter { !$0.isEmpty }
        guard !ownerPrefixes.isEmpty else { return [] }
        return allSessionNames.compactMap { rawName in
            guard rawName.hasPrefix(sessionPrefix) else { return nil }
            let bareName = String(rawName.dropFirst(sessionPrefix.count))
            guard ownerPrefixes.contains(where: { bareName.hasPrefix($0) }),
                  !knownNames.contains(bareName)
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

    /// Await in-flight zmx kills without blocking the MainActor. Used by
    /// interactive checkout lifecycle flows where the UI must stay responsive
    /// while archive waits for owned processes to stop.
    func drainPendingKills(timeout: TimeInterval) async {
        let tasks = pendingKillTasks
        guard !tasks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { kills in
                    for task in tasks {
                        kills.addTask { await task.value }
                    }
                    for await _ in kills {}
                }
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            _ = await group.next()
            group.cancelAll()
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

    nonisolated static func effectiveStartupScript(
        global: AppConfig.Terminal,
        project: ProjectConfig,
        includeUserStartupScript: Bool,
        startupScriptSuffix: String?
    ) -> String {
        let baseScript = includeUserStartupScript
            ? StartupScriptResolver.sessionOpenScript(global: global, project: project)
            : ""
        return composeStartupScript(
            userStartupScript: baseScript,
            startupScriptSuffix: startupScriptSuffix
        )
    }

    private nonisolated static func composeStartupScript(
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
        sessionNamesForCleanup(
            worktreeId: worktreeId,
            projectPath: projectPath,
            leafId: leafId,
            legacySessionInfos: zmxClient.listSessionInfos()
        )
    }

    nonisolated private static func sessionNamesForCleanup(
        worktreeId: String,
        projectPath: String?,
        leafId: String,
        legacySessionInfos: [ZmxSessionInfo]
    ) -> [String] {
        let scoped = ZmxSessionName.derive(worktreeId: worktreeId, leafId: leafId)
        let legacy = ZmxSessionName.legacy(leafId: leafId)
        let roots = [worktreeId] + (projectPath.map { [$0] } ?? [])
        guard legacySessionBelongsToKnownRoot(legacy, roots: roots, sessionInfos: legacySessionInfos) else {
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
