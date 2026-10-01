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
    @ObservationIgnored let catalog: PluginCatalog
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
        actions: @escaping (ProjectConfig) -> PluginHostActions,
        catalog: PluginCatalog = PluginCatalog()
    ) {
        self.directory = directory
        self.catalog = catalog
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

    /// Downloads `version` of the catalog entry `id`, checks it against the catalog's hash, and replaces
    /// the folder named after the id. The new files are unapproved, so nothing runs until the user approves.
    /// Returns the failure to show, or nil.
    func install(id: String, _ version: PluginCatalogIndex.Version) async -> String? {
        var failure: String?
        await serialized {
            do {
                try await self.performInstall(id: id, version)
                await self.performReload()
            } catch {
                // Nothing was stopped or replaced, so the installed version keeps running untouched.
                failure = (error as? PluginCatalogError)?.description ?? error.localizedDescription
            }
        }
        return failure
    }

    /// Deletes a plugin the catalog installed. Its approval and stored data stay, so reinstalling keeps them.
    func uninstall(_ plugin: Plugin) async {
        await serialized {
            await self.stopHosts { $0.pluginID == plugin.id }
            try? FileManager.default.removeItem(at: plugin.folder)
            await self.performReload()
        }
    }

    private func performInstall(id: String, _ version: PluginCatalogIndex.Version) async throws {
        guard let entryURL = version.entry else { throw PluginCatalogError.hashMismatch }
        let manifestData = try await catalog.fetch(version.manifest)
        let source = try await catalog.fetch(entryURL)
        guard PluginTrust.hash(manifest: manifestData, entry: source) == version.hash else {
            throw PluginCatalogError.hashMismatch
        }
        let manifest = try PluginManifest.parse(manifestData)
        guard manifest.id == id else { throw PluginCatalogError.wrongPlugin(manifest.id) }
        // Built in a hidden staging folder, which discovery skips, then moved into place in one step.
        let fileManager = FileManager.default
        let staging = directory.appending(path: ".staging/\(id)")
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(
            at: staging.appending(path: manifest.entry).deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifestData.write(to: staging.appending(path: "plugin.json"))
        try source.write(to: staging.appending(path: manifest.entry))
        await stopHosts { $0.pluginID == id }
        let target = directory.appending(path: id)
        do {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
        } catch {
            await performReload()  // restarts the version still in place
            throw error
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
        for (key, host) in hostsByKey where host.state == .active
            && (host.grants.contains(.workspaceRead) || host.receivesSessionEvents) {
            guard let project = projectsByID[key.projectID] else { continue }
            let snapshot = actions(project).snapshot()
            let previous = lastSnapshots[key]
            guard snapshot != previous else { continue }
            lastSnapshots[key] = snapshot
            await host.workspaceChanged(snapshot)
            // The first snapshot after a start is the baseline, so a restart does not replay every session.
            if let previous { await host.sessionEvents(snapshot.sessionEvents(since: previous)) }
        }
    }

    /// Every sub-folder with a `plugin.json`. Folders that fail validation, and
    /// all folders sharing a duplicate id, are reported instead of loaded.
    nonisolated static func discover(in directory: URL) -> (plugins: [Plugin], invalid: [Invalid]) {
        let fileManager = FileManager.default
        let folders = ((try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
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
        var loaded: [Plugin] = []
        for plugin in found {
            let copies = found.filter { $0.id == plugin.id }
            if copies.count == 1 {
                loaded.append(plugin)
                continue
            }
            // A copy built by hand beats the one the catalog put in `Plugins/<id>`; any other duplicate is ambiguous.
            let catalogCopies = copies.filter { $0.folder.lastPathComponent == $0.id }
            if copies.count == 2, catalogCopies.count == 1, let local = copies.first(where: { $0.folder.lastPathComponent != $0.id }) {
                if plugin.folder == local.folder {
                    loaded.append(plugin)
                } else {
                    invalid.append(Invalid(folder: plugin.folder, reason: "shadowed by \(local.folder.lastPathComponent), which has the same id"))
                }
            } else {
                invalid.append(Invalid(folder: plugin.folder, reason: "duplicate plugin id \(plugin.id)"))
            }
        }
        return (loaded, invalid)
    }
}
