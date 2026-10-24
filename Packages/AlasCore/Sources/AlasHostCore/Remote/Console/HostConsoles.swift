import Foundation
import os
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasACP

private let consolesLogger = Logger(subsystem: "io.nlopez.alas", category: "HostConsoles")

public struct HostConsoleEntry: Codable, Equatable, Sendable {
    public let id: String
    public let worktreeId: String
    public var title: String
    public let zmxName: String
    public var rows: Int
    public var columns: Int

    public init(id: String, worktreeId: String, title: String, zmxName: String, rows: Int, columns: Int) {
        self.id = id
        self.worktreeId = worktreeId
        self.title = title
        self.zmxName = zmxName
        self.rows = rows
        self.columns = columns
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
    }

    public var isAvailable: Bool { zmx.isAvailable }

    /// Loads the saved registry, keeping only shells whose zmx session is
    /// still running: one that exited while the host was down is dropped.
    public func restore() async {
        let saved: [HostConsoleEntry]
        do {
            saved = try store.readIfExists(HostConsolesFile.self, from: fileURL)?.consoles ?? []
        } catch {
            consolesLogger.error("Could not read host consoles: \(String(describing: error), privacy: .public)")
            return
        }
        let zmx = zmx
        let listed = await BlockingWork.run { zmx.listSessionsIfAvailable() }
        let kept: [HostConsoleEntry]
        if let listed {
            let live = Set(listed)
            let prefix = ProcessInfo.processInfo.environment["ZMX_SESSION_PREFIX"] ?? ""
            kept = saved.filter { live.contains(prefix + $0.zmxName) }
        } else {
            // Unknown is not gone: dropping would orphan running daemons.
            // `summaries()` still prunes shells whose socket is missing.
            consolesLogger.error("Could not list zmx sessions; keeping saved host consoles")
            kept = saved
        }
        // Shells opened while `zmx ls` ran are kept too.
        let savedIds = Set(saved.map(\.id))
        entries = kept + entries.filter { !savedIds.contains($0.id) }
        if entries != saved { save() }
    }

    /// Drops shells whose socket is gone (the user typed `exit`), then lists
    /// the ones in a configured worktree.
    public func summaries() -> [PeerConsoleSummary] {
        let alive = entries.filter { entry in
            zmx.socketPath(forSession: entry.zmxName).map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
        if alive != entries {
            entries = alive
            save()
        }
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
        guard let (project, worktree) = core.projectAndWorktree(withWorktreeId: worktreeId),
              !core.projects.isWorktreeHidden(projectId: project.id, path: worktree.path)
        else { throw PeerConsoleOpenError.worktreeUnavailable }
        guard project.host == nil else { throw PeerConsoleOpenError.sshProject }
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

    /// True when zmx took the size; only then is it remembered.
    public func resize(_ consoleId: String, rows: Int, columns: Int) async -> Bool {
        guard let socketPath = target(consoleId)?.socketPath else { return false }
        let applySize = applySize
        guard await BlockingWork.run({ applySize(socketPath, rows, columns) }),
              let index = entries.firstIndex(where: { $0.id == consoleId }) else { return false }
        entries[index].rows = rows
        entries[index].columns = columns
        save()
        return true
    }

    public func terminate(_ consoleId: String) {
        guard let index = entries.firstIndex(where: { $0.id == consoleId }) else { return }
        let name = entries.remove(at: index).zmxName
        save()
        let zmx = zmx
        BlockingWork.detach { zmx.killSession(name: name) }
    }

    public func makePeerConsoleHost() -> PeerConsoleHost {
        PeerConsoleHost(environment: PeerConsoleHost.Environment(
            consoles: { self.summaries() },
            resolve: { self.target($0) },
            setLocalInputSuppressed: { _, _ in },
            terminate: { self.terminate($0) },
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
