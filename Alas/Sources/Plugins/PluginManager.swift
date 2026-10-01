import Foundation
import Observation

/// Discovers plugins, holds approvals, and runs one `PluginHost` per approved
/// plugin per project.
@MainActor
@Observable
final class PluginManager {
    struct Plugin: Identifiable, Sendable {
        let folder: URL
        let manifest: PluginManifest
        let source: Data
        let hash: String
        var id: String { manifest.id }
    }

    struct Invalid: Identifiable, Sendable {
        let folder: URL
        let reason: String
        var id: String { folder.path }
    }

    struct HostKey: Hashable, Sendable {
        let pluginID: String
        let projectID: String
    }

    /// Follows the profile, so an isolated instance (`ALAS_APP_SUPPORT_DIR`) has its own plugins.
    static var defaultDirectory: URL {
        Paths.appSupportRoot.appending(path: "Plugins")
    }

    private(set) var plugins: [Plugin] = []
    private(set) var invalid: [Invalid] = []
    private(set) var hostsByKey: [HostKey: PluginHost] = [:]

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let approvals: PluginApprovalStore
    @ObservationIgnored private let projects: () -> [ProjectConfig]
    @ObservationIgnored private let actions: (ProjectConfig) -> PluginHostActions
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var lastSnapshots: [HostKey: PluginWorkspaceSnapshot] = [:]
    @ObservationIgnored private var lastOperation: Task<Void, Never> = Task {}

    init(
        directory: URL = PluginManager.defaultDirectory,
        approvals: PluginApprovalStore = PluginApprovalStore(),
        projects: @escaping () -> [ProjectConfig],
        actions: @escaping (ProjectConfig) -> PluginHostActions
    ) {
        self.directory = directory
        self.approvals = approvals
        self.projects = projects
        self.actions = actions
    }

    func isApproved(_ plugin: Plugin) -> Bool {
        approvals.approval(id: plugin.id, hash: plugin.hash) != nil
    }

    func isEnabled(_ plugin: Plugin) -> Bool { !approvals.isDisabled(id: plugin.id) }

    func plugin(id: String) -> Plugin? { plugins.first { $0.id == id } }

    func host(pluginID: String, projectID: String) -> PluginHost? {
        hostsByKey[HostKey(pluginID: pluginID, projectID: projectID)]
    }

    static let tickInterval: Duration = .milliseconds(66)  // 15 fps

    func hosts(for plugin: Plugin) -> [(key: HostKey, host: PluginHost)] {
        hostsByKey.filter { $0.key.pluginID == plugin.id }
            .map { (key: $0.key, host: $0.value) }
            .sorted { $0.host.project.name < $1.host.project.name }
    }

    /// Runs `operation` after every earlier one has finished, so reload, approve and restart never
    /// interleave across their suspension points and act on a plugin list that has since changed.
    private func serialized(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = lastOperation
        let current = Task { @MainActor in
            await previous.value
            await operation()
        }
        lastOperation = current
        await current.value
    }

    /// Stops everything, rescans the folder, and starts approved plugins for
    /// every project.
    func reload() async {
        await serialized { await self.performReload() }
    }

    /// Approves `plugin` as shown to the user. Ignored when a rescan has since found different files,
    /// because the new version is a different plugin that has not been approved.
    func approve(_ plugin: Plugin) async {
        await serialized { await self.performApprove(plugin) }
    }

    func restart(_ key: HostKey) async {
        await serialized { await self.performRestart(key) }
    }

    func setEnabled(_ plugin: Plugin, _ enabled: Bool) async {
        await serialized {
            self.approvals.setDisabled(id: plugin.id, !enabled)
            if enabled {
                // `plugin` is the row the user saw. A rescan may have replaced it since, so start what is
                // discovered now: `start` then checks the current files' approval, never stale bytes.
                if let current = self.plugin(id: plugin.id) { await self.start(current) }
            } else {
                await self.stopHosts { $0.pluginID == plugin.id }
            }
        }
    }

    func revoke(_ plugin: Plugin) async {
        await serialized {
            self.approvals.revoke(id: plugin.id)
            await self.stopHosts { $0.pluginID == plugin.id }
        }
    }

    /// Starts hosts for projects added since the last pass and stops hosts whose project is gone.
    func reconcile() async {
        await serialized {
            let projectIDs = Set(self.projects().map(\.id))
            await self.stopHosts { !projectIDs.contains($0.projectID) }
            for plugin in self.plugins { await self.start(plugin) }
        }
    }

    /// Stops every loop and host. The manager is not reused afterwards.
    func shutdown() async {
        await serialized {
            self.isShutDown = true
            self.snapshotTask?.cancel()
            self.tickTask?.cancel()
            await self.stopHosts { _ in true }
        }
    }

    private func stopHosts(where matches: (HostKey) -> Bool) async {
        for key in hostsByKey.keys.filter(matches) {
            await hostsByKey[key]?.deactivate()
            hostsByKey[key] = nil
            lastSnapshots[key] = nil
        }
    }

    private func performReload() async {
        guard !isShutDown else { return }
        snapshotTask?.cancel()
        await stopHosts { _ in true }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        (plugins, invalid) = Self.discover(in: directory)
        for plugin in plugins where isApproved(plugin) { await start(plugin) }
        startSnapshotLoop()
        startTickLoop()
    }

    private func performApprove(_ plugin: Plugin) async {
        guard plugins.contains(where: { $0.id == plugin.id && $0.hash == plugin.hash }) else { return }
        approvals.approve(PluginApproval(id: plugin.id, hash: plugin.hash, capabilities: plugin.manifest.capabilities))
        await start(plugin)
    }

    private func performRestart(_ key: HostKey) async {
        guard let host = hostsByKey[key] else { return }
        await host.deactivate()
        lastSnapshots[key] = nil
        await host.activate()
    }

    private func start(_ plugin: Plugin) async {
        guard !isShutDown, isEnabled(plugin), let approval = approvals.approval(id: plugin.id, hash: plugin.hash) else { return }
        for project in projects() {
            let key = HostKey(pluginID: plugin.id, projectID: project.id)
            guard hostsByKey[key] == nil else { continue }
            let host = PluginHost(
                manifest: plugin.manifest, source: plugin.source,
                project: PluginProjectRef(id: project.id, name: project.name),
                grants: Set(approval.capabilities), actions: actions(project),
                storage: PluginStorage.shared(file: PluginStorage.file(pluginID: plugin.id, projectID: project.id)))
            hostsByKey[key] = host
            await host.activate()
        }
    }

    // ponytail: polls every 500 ms, reconciles projects, and diffs, because agent state mixes ObservableObject
    // and @Observable sources; switch to change notifications if the rebuild shows up in profiles.
    private func startSnapshotLoop() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                await self?.pushChangedSnapshots()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // ponytail: one fixed-rate loop for all hosts; a host with no visible tab returns immediately.
    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.fireTicks()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func fireTicks() {
        let now = ContinuousClock.now
        // Each host ticks independently, so one slow plugin cannot delay another's frames.
        for host in hostsByKey.values where host.isTicking {
            Task { await host.tick(at: now) }
        }
    }

    private func pushChangedSnapshots() async {
        let projectsByID = Dictionary(projects().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, host) in hostsByKey where host.state == .active && host.grants.contains(.workspaceRead) {
            guard let project = projectsByID[key.projectID] else { continue }
            let snapshot = actions(project).snapshot()
            guard snapshot != lastSnapshots[key] else { continue }
            lastSnapshots[key] = snapshot
            await host.workspaceChanged(snapshot)
        }
    }

    /// Every sub-folder with a `plugin.json`. Folders that fail validation, and
    /// all folders sharing a duplicate id, are reported instead of loaded.
    nonisolated static func discover(in directory: URL) -> (plugins: [Plugin], invalid: [Invalid]) {
        let fileManager = FileManager.default
        let folders = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.resolvingSymlinksInPath() }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path < $1.path }
        var found: [Plugin] = []
        var invalid: [Invalid] = []
        for folder in folders {
            do {
                let manifestData = try Data(contentsOf: folder.appending(path: "plugin.json"))
                let manifest = try PluginManifest.parse(manifestData)
                let entry = folder.appending(path: manifest.entry)
                // `folder` is already resolved, so the resolved entry must stay beneath it. That catches a
                // symlinked directory in the path; the regular-file check catches a symlink as the file.
                guard entry.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/"),
                      (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else {
                    throw PluginManifestError.invalidEntry(manifest.entry)
                }
                let source = try Data(contentsOf: entry)
                found.append(Plugin(
                    folder: folder, manifest: manifest, source: source,
                    hash: PluginTrust.hash(manifest: manifestData, entry: source)))
            } catch {
                invalid.append(Invalid(folder: folder, reason: String(describing: error)))
            }
        }
        let duplicateIDs = Set(Dictionary(grouping: found, by: \.id).filter { $0.value.count > 1 }.keys)
        invalid += found.filter { duplicateIDs.contains($0.id) }
            .map { Invalid(folder: $0.folder, reason: "duplicate plugin id \($0.id)") }
        return (found.filter { !duplicateIDs.contains($0.id) }, invalid)
    }
}
