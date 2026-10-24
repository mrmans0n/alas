import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasACP
import AlasFeatures

private let consolesLogger = Logger(subsystem: "io.nlopez.alas", category: "HostConsoles")

public struct HostConsoleEntry: Codable, Equatable, Sendable {
    public let id: String
    public let worktreeId: String
    public var title: String
    public let zmxName: String
    public var rows: Int
    public var columns: Int
    /// The run script this console hosts; nil for a shell. Absent in files
    /// written before runs had consoles.
    public let scriptKey: String?

    public init(id: String, worktreeId: String, title: String, zmxName: String, rows: Int, columns: Int, scriptKey: String? = nil) {
        self.id = id
        self.worktreeId = worktreeId
        self.title = title
        self.zmxName = zmxName
        self.rows = rows
        self.columns = columns
        self.scriptKey = scriptKey
    }
}

/// The shells a headless host serves as consoles, in open order.
public struct HostConsolesFile: Codable, Equatable {
    public var consoles: [HostConsoleEntry]

    public init(consoles: [HostConsoleEntry]) {
        self.consoles = consoles
    }
}

/// Stands in for the app's terminal registry on a headless host: login
/// shells in detached zmx sessions that paired peers open, view and size.
@_spi(AppHost) @MainActor
public final class HostConsoles {
    /// What zmx gives a daemon launched without a TTY (`stty size`).
    private static let launchRows = 24
    private static let launchColumns = 120

    private let core: AlasCoreContext
    private let zmx: ZmxClient
    private let store: any PersistenceStoreProtocol
    private let fileURL: URL
    private let launch: @Sendable (HostShellLaunch) async throws -> Void
    private let applySize: @Sendable (_ socketPath: String, _ rows: Int, _ columns: Int) -> Bool
    private let baseEnvironment: @Sendable () -> [String: String]
    private let shell: String
    private var entries: [HostConsoleEntry] = []
    private var pendingSizes: [String: (rows: Int, columns: Int)] = [:]
    private var resizing: Set<String> = []

    public init(
        core: AlasCoreContext,
        zmx: ZmxClient,
        store: any PersistenceStoreProtocol = PersistenceStore(),
        fileURL: URL = Paths.hostConsolesFile,
        launch: @escaping @Sendable (HostShellLaunch) async throws -> Void = { try await $0.run() },
        applySize: @escaping @Sendable (_ socketPath: String, _ rows: Int, _ columns: Int) -> Bool = ZmxIPCSocket.resize,
        baseEnvironment: @escaping @Sendable () -> [String: String] = { ACPProcessEnvironment.baseEnvironment() },
        shell: String = HostShellLaunch.loginShell()
    ) {
        self.core = core
        self.zmx = zmx
        self.store = store
        self.fileURL = fileURL
        self.launch = launch
        self.applySize = applySize
        self.baseEnvironment = baseEnvironment
        self.shell = shell
        // Loaded now, so the registry guards removals before `restore()`
        // has asked zmx which shells are still running.
        do {
            entries = try store.readIfExists(HostConsolesFile.self, from: fileURL)?.consoles ?? []
        } catch {
            consolesLogger.error("Could not read host consoles: \(String(describing: error), privacy: .public)")
        }
    }

    /// The registry `alas-host` keeps on every boot, Remote on or off,
    /// guarding worktree and project removal from the start. Serving its
    /// shells to peers is separate.
    public static func install(
        on core: AlasCoreContext,
        zmx: ZmxClient = ZmxClient(env: .resolve(binaryURL: HostShellLaunch.zmxBinary(executable: Bundle.main.executableURL))),
        fileURL: URL = Paths.hostConsolesFile
    ) -> HostConsoles {
        let consoles = HostConsoles(core: core, zmx: zmx, fileURL: fileURL)
        // A deleted worktree's shells would outlive it unlisted and unclosable;
        // forgetting their project would hide them the same way.
        core.willRemoveWorktree = { try await consoles.terminateConsoles(inWorktree: $0) }
        core.hasHostConsoles = { consoles.hasConsoles(inWorktrees: $0) }
        (core.environment as? HeadlessHostEnvironment)?.runLauncherOverride = consoles
        return consoles
    }

    public var isAvailable: Bool { zmx.isAvailable }

    /// Drops saved shells whose zmx session is gone: one that exited while
    /// the host was down.
    public func restore() async {
        let listedBefore = Set(entries.map(\.id))
        let zmx = zmx
        guard let listed = await BlockingWork.run({ zmx.listSessionsIfAvailable() }) else {
            // Unknown is not gone: dropping would orphan running daemons.
            // `summaries()` still prunes shells whose socket is missing.
            consolesLogger.error("Could not list zmx sessions; keeping saved host consoles")
            return
        }
        let live = Set(listed)
        let prefix = ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? ""
        // Shells opened while `zmx ls` ran weren't listed, and are kept.
        let alive = entries.filter { !listedBefore.contains($0.id) || live.contains(prefix + $0.zmxName) }
        guard alive != entries else { return }
        entries = alive
        save()
    }

    /// Drops shells whose socket is gone (the user typed `exit`), then lists
    /// the ones in a configured worktree.
    public func summaries() -> [PeerConsoleSummary] {
        pruneExited()
        // Hidden (archived) worktrees are listed on purpose, so their shells
        // can still be seen and terminated; `open` refuses them.
        return entries.compactMap { entry in
            guard let (project, worktree) = core.projectAndWorktree(withWorktreeId: entry.worktreeId) else { return nil }
            return PeerConsoleSummary(
                consoleId: entry.id,
                title: entry.title,
                worktreeId: entry.worktreeId,
                projectId: project.id,
                projectName: project.name,
                worktreeName: worktree.name,
                rows: entry.rows,
                columns: entry.columns,
                worktree: RemoteWorktreeSummaryBuilder.make(
                    projectName: project.name,
                    worktree: worktree,
                    isMain: core.projects.isMain(worktree, in: project),
                    isFolder: project.isFolder,
                    metrics: .unavailable
                ),
                tabIndex: entries.filter { $0.worktreeId == entry.worktreeId }.firstIndex(of: entry)
            )
        }
    }

    public func target(_ consoleId: String) -> PeerConsoleTarget? {
        guard let entry = entries.first(where: { $0.id == consoleId }),
              let socketPath = zmx.socketPath(forSession: entry.zmxName) else { return nil }
        return PeerConsoleTarget(consoleId: entry.id, socketPath: socketPath, rows: entry.rows, columns: entry.columns)
    }

    // ponytail: no per-peer open limit; pairing is the trust boundary (spec). Cap here if a peer misbehaves.
    public func open(worktreeId: String) async throws -> String {
        guard isAvailable else { throw PeerConsoleOpenError.zmxMissing }
        let worktree = try admittedWorktree(worktreeId)
        await ShellEnvResolver.shared.waitUntilResolved()
        let id = UUID().uuidString
        let name = ZmxSessionName.hostShell(worktreeId: worktreeId, consoleId: id)
        guard let shellLaunch = HostShellLaunch.make(
            zmx: zmx, sessionName: name, directory: worktree.path, shell: shell, baseEnvironment: baseEnvironment()
        ) else { throw PeerConsoleOpenError.zmxMissing }
        do {
            try await launch(shellLaunch)
        } catch {
            // A launcher that timed out or failed may have forked the daemon
            // already; without an entry nothing would ever close it.
            let zmx = zmx
            await BlockingWork.run { zmx.killSession(name: name) }
            throw (error as? PeerConsoleOpenError) ?? .notStarted
        }
        // The launch suspended: a removal that claimed or deleted the
        // worktree meanwhile has already run its cleanup without this shell.
        do {
            _ = try admittedWorktree(worktreeId)
        } catch {
            let zmx = zmx
            await BlockingWork.run { zmx.killSession(name: name) }
            throw error
        }
        // Numbered after the launch, with no suspension before the append,
        // so concurrent opens can't take the same title.
        let taken = Set(entries.filter { $0.worktreeId == worktreeId }.map(\.title))
        let number = (1...).first { !taken.contains("Terminal \($0)") } ?? 1
        entries.append(HostConsoleEntry(
            id: id, worktreeId: worktreeId, title: "Terminal \(number)", zmxName: name,
            rows: Self.launchRows, columns: Self.launchColumns
        ))
        save()
        return id
    }

    /// The worktree a shell may run in now: listed, visible, local, and not
    /// claimed by a lifecycle operation.
    private func admittedWorktree(_ worktreeId: String) throws -> Worktree {
        guard let (project, worktree) = core.projectAndWorktree(withWorktreeId: worktreeId),
              !core.projects.isWorktreeHidden(projectId: project.id, path: worktree.path)
        else { throw PeerConsoleOpenError.worktreeUnavailable }
        guard project.host == nil else { throw PeerConsoleOpenError.sshProject }
        guard core.projects.admitsNewWork(in: worktree) else { throw PeerConsoleOpenError.worktreeBusy }
        return worktree
    }

    /// Applies the newest requested size, one apply at a time per console:
    /// during a window drag a later size replaces a pending one, so zmx and
    /// the registry end on the same size. Returns the size zmx took last
    /// (only that is remembered), or nil when none applied or another call
    /// is applying this console's sizes.
    public func resize(_ consoleId: String, rows: Int, columns: Int) async -> (rows: Int, columns: Int)? {
        pendingSizes[consoleId] = (rows, columns)
        guard resizing.insert(consoleId).inserted else { return nil }
        defer {
            resizing.remove(consoleId)
            pendingSizes[consoleId] = nil
        }
        var applied: (rows: Int, columns: Int)?
        while let size = pendingSizes.removeValue(forKey: consoleId),
              let socketPath = target(consoleId)?.socketPath {
            let applySize = applySize
            if await BlockingWork.run({ applySize(socketPath, size.rows, size.columns) }) { applied = size }
        }
        guard let applied, let index = entries.firstIndex(where: { $0.id == consoleId }) else { return nil }
        entries[index].rows = applied.rows
        entries[index].columns = applied.columns
        save()
        return applied
    }

    /// Stops a shell and forgets it once stopped; true when it was. One
    /// zmx couldn't stop stays listed, so the user can try again.
    @discardableResult
    public func terminate(_ consoleId: String) async -> Bool {
        guard let entry = entries.first(where: { $0.id == consoleId }) else { return true }
        return await stop([entry])
    }

    public func hasConsoles(inWorktrees worktreeIDs: Set<String>) -> Bool {
        pruneExited()
        return entries.contains { worktreeIDs.contains($0.worktreeId) }
    }

    /// Forgets shells whose socket is gone: they exited (the user typed
    /// `exit`), whether or not a peer was watching. Without zmx no path
    /// resolves, and unknown is not gone, so those are kept.
    private func pruneExited() {
        let alive = entries.filter { entry in
            zmx.socketPath(forSession: entry.zmxName).map { FileManager.default.fileExists(atPath: $0) } ?? true
        }
        guard alive != entries else { return }
        entries = alive
        save()
    }

    /// Some shells could not be stopped; they stay in the registry.
    public struct StopFailed: Error, Equatable {}

    /// Kills and forgets every shell in a worktree that is being deleted, so
    /// none outlives its checkout unlisted. A shell zmx can't stop (zmx is
    /// missing, or the kill failed while its socket remains) is kept, and the
    /// call throws `StopFailed`. Archive keeps the checkout and its shells.
    public func terminateConsoles(inWorktree worktreeID: String) async throws {
        let doomed = entries.filter { $0.worktreeId == worktreeID }
        guard !doomed.isEmpty else { return }
        guard await stop(doomed) else { throw StopFailed() }
    }

    /// Kills each shell, then forgets those that stopped: the kill succeeded
    /// or the socket is confirmed gone. True when all of them did.
    private func stop(_ doomed: [HostConsoleEntry]) async -> Bool {
        // Without zmx a kill reports success without running.
        guard zmx.isAvailable else { return false }
        let zmx = zmx
        let stopped = await BlockingWork.run {
            Set(doomed.filter { entry in
                zmx.killSessionResult(name: entry.zmxName)
                    || zmx.socketPath(forSession: entry.zmxName).map { !FileManager.default.fileExists(atPath: $0) } == true
            }.map(\.id))
        }
        if entries.contains(where: { stopped.contains($0.id) }) {
            entries.removeAll { stopped.contains($0.id) }
            save()
        }
        return stopped.count == doomed.count
    }

    public func makePeerConsoleHost() -> PeerConsoleHost {
        PeerConsoleHost(environment: PeerConsoleHost.Environment(
            consoles: { self.summaries() },
            resolve: { self.target($0) },
            setLocalInputSuppressed: { _, _ in },
            terminate: { id in Task { await self.terminate(id) } },
            open: { try await self.open(worktreeId: $0) },
            resize: { await self.resize($0, rows: $1, columns: $2) }
        ))
    }

    private func save() {
        do {
            try store.write(HostConsolesFile(consoles: entries), to: fileURL)
        } catch {
            consolesLogger.error("Could not save host consoles: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Headless runs launch in consoles, as the app's run in tabs: the login
/// shell sources the captured command, so peers can attach and watch.
/// Without zmx, or with a shell the command can't be injected into, a run
/// is a plain process as before.
extension HostConsoles: RunLauncher {
    public func refusal(for script: RunScript, in worktree: Worktree, project: ProjectConfig) -> String? {
        HeadlessRunLauncher.shared.refusal(for: script, in: worktree, project: project)
    }

    public func launch(_ request: RunLaunchRequest, in core: AlasCoreContext) async throws -> RunLaunch {
        guard isAvailable, StartupScriptInstaller.supportsStartupScriptInjection(shell: shell) else {
            return try await HeadlessRunLauncher.shared.launch(request, in: core)
        }
        let worktreeId = request.worktree.id
        let worktree = try admittedWorktree(worktreeId)
        await ShellEnvResolver.shared.waitUntilResolved()
        // One console per script and worktree, as in the app.
        _ = await stop(entries.filter { $0.worktreeId == worktreeId && $0.scriptKey == request.script.key })
        let id = UUID().uuidString
        let name = ZmxSessionName.hostShell(worktreeId: worktreeId, consoleId: id)
        let plan = try StartupScriptInstaller.plan(shell: shell, startupScript: request.command, sessionId: id)
        guard let shellLaunch = HostShellLaunch.make(
            zmx: zmx, sessionName: name, directory: worktree.path, shell: shell,
            shellArguments: plan.args, environmentOverrides: plan.envOverrides, baseEnvironment: baseEnvironment()
        ) else { throw PeerConsoleOpenError.zmxMissing }
        do {
            try await launch(shellLaunch)
        } catch {
            // `attach` also fails when the command exits before it connects,
            // though it ran. With the daemon killed and no entry, the run
            // settles by its completion file, or as unknown after the grace.
            let zmx = zmx
            await BlockingWork.run { zmx.killSession(name: name) }
            return .hosted(sessionID: id)
        }
        // The launch suspended: a removal may have claimed or deleted the
        // worktree meanwhile, and its cleanup ran without this shell.
        do {
            _ = try admittedWorktree(worktreeId)
        } catch {
            let zmx = zmx
            await BlockingWork.run { zmx.killSession(name: name) }
            throw error
        }
        entries.append(HostConsoleEntry(
            id: id, worktreeId: worktreeId, title: request.script.displayName, zmxName: name,
            rows: Self.launchRows, columns: Self.launchColumns, scriptKey: request.script.key
        ))
        save()
        return .hosted(sessionID: id)
    }

    public func hostSessionExists(_ sessionID: String) -> Bool {
        pruneExited()
        return entries.contains { $0.id == sessionID }
    }

    /// A gone socket means the shell exited.
    public func hostSessionIsIdle(_ sessionID: String) -> Bool {
        !hostSessionExists(sessionID)
    }
}
