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
        /// Reached through a symlink in the plugins folder: someone else's files, which the catalog never
        /// replaces or deletes.
        var isLinked = false
        var id: String { manifest.id }
        /// In `Plugins/<id>` itself, where the catalog installs: the only copies it may update or remove.
        var isCatalogFolder: Bool { !isLinked && folder.lastPathComponent == id }
    }

    struct Invalid: Identifiable, Sendable {
        let folder: URL
        let reason: String
        /// Set when the folder holds a valid plugin that lost to a duplicate of the same id.
        var pluginID: String?
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
    /// Plugins whose folder is exactly a catalog release, as of the last scan: the ones Remove and Update may touch.
    private(set) var catalogOwnedIDs: Set<String> = []
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
    @ObservationIgnored private var settingsByPlugin: [String: PluginSettings] = [:]
    @ObservationIgnored private let makeSettings: (PluginManifest) -> PluginSettings

    init(
        directory: URL = PluginManager.defaultDirectory,
        approvals: PluginApprovalStore = PluginApprovalStore(),
        projects: @escaping () -> [ProjectConfig],
        actions: @escaping (ProjectConfig) -> PluginHostActions,
        catalog: PluginCatalog = PluginCatalog(),
        makeSettings: @escaping (PluginManifest) -> PluginSettings = {
            PluginSettings.make(pluginID: $0.id, declared: $0.settings)
        }
    ) {
        self.directory = directory
        self.catalog = catalog
        self.approvals = approvals
        self.projects = projects
        self.actions = actions
        self.makeSettings = makeSettings
    }

    /// One per discovered plugin, so the form and every host share it; a change reaches each running host.
    func settings(for plugin: Plugin) -> PluginSettings {
        if let existing = settingsByPlugin[plugin.id], existing.declared == plugin.manifest.settings { return existing }
        let settings = makeSettings(plugin.manifest)
        settings.didChange = { [weak self] in
            guard let self else { return }
            for (key, host) in self.hostsByKey where key.pluginID == plugin.id {
                Task { await host.settingsChanged() }
            }
        }
        settingsByPlugin[plugin.id] = settings
        return settings
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

    /// Where the catalog stages a download: next to the plugins folder, so moving it in is one step on the same
    /// volume, and outside it, so it never overlaps a folder someone named.
    var stagingDirectory: URL {
        directory.deletingLastPathComponent().appending(path: ".\(directory.lastPathComponent)-staging")
    }

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
    func install(_ entry: PluginCatalogIndex.Entry, _ version: PluginCatalogIndex.Version) async -> String? {
        func describe(_ error: Error) -> String { (error as? PluginCatalogError)?.description ?? error.localizedDescription }
        // Downloaded and checked outside the serialized queue, so a slow server never holds up reloads or shutdown.
        let download: (manifest: PluginManifest, manifestData: Data, source: Data)
        do {
            download = try await self.download(entry, version)
        } catch {
            return describe(error)
        }
        var failure: String?
        await serialized {
            // Plugins were turned off while it downloaded: the manager is gone, so nothing is written.
            guard !self.isShutDown else {
                failure = "Plugins were turned off."
                return
            }
            do {
                try await self.performInstall(entry, version, download)
                await self.performRescan()
            } catch {
                // Nothing was stopped or replaced, so the installed version keeps running untouched.
                failure = describe(error)
            }
        }
        return failure
    }

    /// Deletes a plugin the catalog installed. Its approval and stored data stay, so reinstalling keeps them.
    /// Returns the failure to show, or nil.
    func uninstall(_ plugin: Plugin) async -> String? {
        var failure: String?
        await serialized {
            await self.stopHosts { $0.pluginID == plugin.id }
            // Checked on disk after the last suspension, right before deleting: files changed since the scan the
            // row came from, or while the hosts stopped, are not the catalog's.
            if let current = self.catalogInstall(id: plugin.id), current.hash == plugin.hash {
                do {
                    try FileManager.default.removeItem(at: current.folder)
                } catch {
                    failure = "Could not remove the plugin: \(error.localizedDescription)"
                }
            } else {
                failure = PluginCatalogError.installedLocally.description
            }
            await self.performRescan()
        }
        return failure
    }

    /// The catalog's own install of `id` as it is on disk right now: a real `Plugins/<id>` folder, not linked.
    private func catalogInstall(id: String) -> Plugin? {
        Self.discover(in: directory).plugins.first { $0.id == id && Self.isCatalogOwned($0) }
    }

    /// In `Plugins/<id>` and holding nothing but the release's two files, so files someone added are never
    /// deleted by Remove or replaced by Update.
    nonisolated static func isCatalogOwned(_ plugin: Plugin) -> Bool {
        guard plugin.isCatalogFolder else { return false }
        let folder = plugin.folder.standardizedFileURL.path + "/"
        // Every path relative to the folder in the same normalized form, so an entry like `./plugin.js` compares equal.
        func relative(_ url: URL) -> String { String(url.standardizedFileURL.path.dropFirst(folder.count)) }
        let found = (FileManager.default.enumerator(at: plugin.folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .map(relative)
        let entry = plugin.folder.appending(path: plugin.manifest.entry)
        let release = Set(["plugin.json", relative(entry)])
        // The entry may sit in a subfolder, which the enumerator lists too.
        var folders: Set<String> = []
        var parent = entry.standardizedFileURL.deletingLastPathComponent()
        while parent.path.count + 1 > folder.count {
            folders.insert(relative(parent))
            parent = parent.deletingLastPathComponent()
        }
        return Set(found).subtracting(folders) == release
    }

    /// Whether something the catalog did not install sits at `Plugins/<id>`, symlinks included, without following one.
    func catalogPathIsTaken(id: String) -> Bool {
        let path = directory.appending(path: id).path
        guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else { return false }
        return !catalogOwnedIDs.contains(id)
    }

    /// The release's two files, checked against the record before anything is written.
    private func download(
        _ entry: PluginCatalogIndex.Entry, _ version: PluginCatalogIndex.Version
    ) async throws -> (manifest: PluginManifest, manifestData: Data, source: Data) {
        let id = entry.id
        guard let entryURL = version.entry else { throw PluginCatalogError.hashMismatch }
        let manifestData = try await catalog.fetch(version.manifest)
        let source = try await catalog.fetch(entryURL)
        guard PluginTrust.hash(manifest: manifestData, entry: source) == version.hash else {
            throw PluginCatalogError.hashMismatch
        }
        let manifest: PluginManifest
        do {
            manifest = try PluginManifest.parse(manifestData)
        } catch {
            throw PluginCatalogError.invalidDownload(String(describing: error))
        }
        guard manifest.id == id else { throw PluginCatalogError.wrongPlugin(manifest.id) }
        // A record that names another release would keep offering itself as an update after installing.
        guard manifest.version == version.version, manifest.api == version.api else {
            throw PluginCatalogError.invalidDownload("it is \(manifest.version) for API \(manifest.api), not the \(version.version) the catalog lists")
        }
        // The row showed the record's capabilities; the download may not ask for anything else.
        guard Set(manifest.capabilities.map(\.rawValue)) == Set(version.capabilities) else {
            throw PluginCatalogError.invalidDownload("it asks for different capabilities than the catalog lists")
        }
        return (manifest, manifestData, source)
    }

    private func performInstall(
        _ entry: PluginCatalogIndex.Entry, _ version: PluginCatalogIndex.Version,
        _ download: (manifest: PluginManifest, manifestData: Data, source: Data)
    ) async throws {
        let id = entry.id
        let (manifest, manifestData, source) = download
        // Built in a hidden staging folder, which discovery skips, then moved into place in one step.
        let fileManager = FileManager.default
        let stagingRoot = stagingDirectory
        // A symlink here would make the cleanup below delete inside its target; replace it with a real folder.
        let rootValues = try? stagingRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if rootValues?.isSymbolicLink == true || (rootValues != nil && rootValues?.isDirectory != true) {
            try fileManager.removeItem(at: stagingRoot)  // removes the link itself, not what it points to
        }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appending(path: id)
        // Leftovers from an earlier attempt must go entirely, or they would be moved in with the release.
        if (try? staging.checkResourceIsReachable()) == true || (try? staging.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.createDirectory(
            at: staging.appending(path: manifest.entry).deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifestData.write(to: staging.appending(path: "plugin.json"))
        try source.write(to: staging.appending(path: manifest.entry))
        // The same checks a rescan applies, before anything running is touched.
        let staged = Self.discover(in: stagingRoot)
        guard staged.plugins.contains(where: { $0.id == id && $0.hash == version.hash }) else {
            throw PluginCatalogError.invalidDownload(staged.invalid.first?.reason ?? "it did not load")
        }
        let target = directory.appending(path: id)
        // A hand-built copy of this plugin elsewhere wins, even one that appeared while the files downloaded. Any copy
        // quarantined as a duplicate means a local one exists too, so adding a catalog copy would only add another.
        func localCopyExists() -> Bool {
            let found = Self.discover(in: directory)
            return found.plugins.contains { $0.id == id && !$0.isCatalogFolder } || found.invalid.contains { $0.pluginID == id }
        }
        // Checked before stopping anything, so a local copy keeps running untouched.
        if localCopyExists() { throw PluginCatalogError.installedLocally }
        await stopHosts { $0.pluginID == id }
        // Checked again after the last suspension, right before replacing: no local copy may have appeared, and
        // something at `Plugins/<id>` is replaced only if it is the catalog's own install of a published version.
        // Otherwise the rescan restarts what was stopped.
        let targetExists = FileManager.default.fileExists(atPath: target.path)
            || (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        let ownsTarget = catalogInstall(id: id).map { current in entry.versions.contains { $0.hash == current.hash } } ?? false
        if localCopyExists() || (targetExists && !ownsTarget) {
            await performRescan()
            throw PluginCatalogError.installedLocally
        }
        do {
            if fileManager.fileExists(atPath: target.path) {
                _ = try fileManager.replaceItemAt(target, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: target)
            }
        } catch {
            await performRescan()  // restarts the version still in place
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

    /// Rescans the folder after the catalog changed it. Unlike a reload, plugins whose files did not change keep
    /// running with their state; only hosts of changed or removed plugins stop, and approved plugins without
    /// hosts start.
    private func performRescan() async {
        guard !isShutDown else { return }
        let before = Dictionary(plugins.map { ($0.id, $0.hash) }, uniquingKeysWith: { first, _ in first })
        (plugins, invalid) = Self.discover(in: directory)
        catalogOwnedIDs = Set(plugins.filter(Self.isCatalogOwned).map(\.id))
        let after = Dictionary(plugins.map { ($0.id, $0.hash) }, uniquingKeysWith: { first, _ in first })
        await stopHosts { before[$0.pluginID] != after[$0.pluginID] }
        for plugin in plugins where isApproved(plugin) { await start(plugin) }
    }

    private func performReload() async {
        guard !isShutDown else { return }
        snapshotTask?.cancel()
        await stopHosts { _ in true }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        (plugins, invalid) = Self.discover(in: directory)
        catalogOwnedIDs = Set(plugins.filter(Self.isCatalogOwned).map(\.id))
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
                storage: PluginStorage.shared(file: PluginStorage.file(pluginID: plugin.id, projectID: project.id)),
                settings: settings(for: plugin))
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
            // The first snapshot after a start is the baseline, so a restart does not replay every session.
            if let previous { await host.sessionEvents(snapshot.sessionEvents(since: previous)) }
            lastSnapshots[key] = snapshot
            await host.workspaceChanged(snapshot)
        }
    }

    /// Every sub-folder with a `plugin.json`. Folders that fail validation, and
    /// all folders sharing a duplicate id, are reported instead of loaded.
    nonisolated static func discover(in directory: URL) -> (plugins: [Plugin], invalid: [Invalid]) {
        let fileManager = FileManager.default
        // Every subfolder, whatever its name.
        let entries = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
        let folders = entries
            .map { (url: $0.resolvingSymlinksInPath(), isLinked: (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true) }
            .filter { (try? $0.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.url.path < $1.url.path }
        var found: [Plugin] = []
        var invalid: [Invalid] = []
        for (folder, isLinked) in folders {
            // Kept for failures after the manifest parsed, so a half-built copy still counts as this plugin.
            var parsedID: String?
            do {
                let manifestData = try Data(contentsOf: folder.appending(path: "plugin.json"))
                let manifest = try PluginManifest.parse(manifestData)
                parsedID = manifest.id
                let entry = folder.appending(path: manifest.entry)
                // `folder` is already resolved, so the resolved entry must stay beneath it. That catches a
                // symlinked directory in the path; the regular-file check catches a symlink as the file.
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard entry.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/"), values?.isRegularFile == true
                else {
                    throw PluginManifestError.invalidEntry(manifest.entry)
                }
                // Checked before reading, so an oversized entry is never loaded or hashed.
                let size = values?.fileSize ?? 0
                guard size <= PluginLimits().maxSourceBytes else {
                    throw PluginRuntimeError.instantiation("script of \(size) bytes exceeds the size limit")
                }
                let source = try Data(contentsOf: entry)
                found.append(Plugin(
                    folder: folder, manifest: manifest, source: source,
                    hash: PluginTrust.hash(manifest: manifestData, entry: source), isLinked: isLinked))
            } catch {
                invalid.append(Invalid(folder: folder, reason: String(describing: error), pluginID: parsedID))
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
            // Only a copy that is exactly a catalog release, in the folder named after its id, gives way.
            let catalogCopies = copies.filter(isCatalogOwned)
            if copies.count == 2, catalogCopies.count == 1, let local = copies.first(where: { !isCatalogOwned($0) }) {
                // Decided by which copy this is, not by its resolved folder: a link may point at the catalog folder.
                if !isCatalogOwned(plugin) {
                    loaded.append(plugin)
                } else {
                    invalid.append(Invalid(
                        folder: plugin.folder, reason: "shadowed by \(local.folder.lastPathComponent), which has the same id",
                        pluginID: plugin.id))
                }
            } else {
                invalid.append(Invalid(folder: plugin.folder, reason: "duplicate plugin id \(plugin.id)", pluginID: plugin.id))
            }
        }
        return (loaded, invalid)
    }
}
