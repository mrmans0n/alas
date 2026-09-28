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
        let wasm: [UInt8]
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

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return appSupport.appending(path: "Alas/Plugins")
    }

    private(set) var plugins: [Plugin] = []
    private(set) var invalid: [Invalid] = []
    private(set) var hostsByKey: [HostKey: PluginHost] = [:]

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let approvals: PluginApprovalStore
    @ObservationIgnored private let projects: () -> [ProjectConfig]
    @ObservationIgnored private let actions: (ProjectConfig) -> PluginHostActions
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshots: [HostKey: PluginWorkspaceSnapshot] = [:]

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

    func hosts(for plugin: Plugin) -> [(key: HostKey, host: PluginHost)] {
        hostsByKey.filter { $0.key.pluginID == plugin.id }
            .map { (key: $0.key, host: $0.value) }
            .sorted { $0.host.project.name < $1.host.project.name }
    }

    /// Stops everything, rescans the folder, and starts approved plugins for
    /// every project. Projects added later need another reload (Debug-only for now).
    func reload() async {
        snapshotTask?.cancel()
        for host in hostsByKey.values { await host.deactivate() }
        hostsByKey = [:]
        lastSnapshots = [:]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        (plugins, invalid) = Self.discover(in: directory)
        for plugin in plugins where isApproved(plugin) { await start(plugin) }
        startSnapshotLoop()
    }

    func approve(_ plugin: Plugin) async {
        approvals.approve(PluginApproval(id: plugin.id, hash: plugin.hash, capabilities: plugin.manifest.capabilities))
        await start(plugin)
    }

    func restart(_ key: HostKey) async {
        guard let host = hostsByKey[key] else { return }
        await host.deactivate()
        lastSnapshots[key] = nil
        await host.activate()
    }

    private func start(_ plugin: Plugin) async {
        guard let approval = approvals.approval(id: plugin.id, hash: plugin.hash) else { return }
        for project in projects() {
            let key = HostKey(pluginID: plugin.id, projectID: project.id)
            guard hostsByKey[key] == nil else { continue }
            let host = PluginHost(
                manifest: plugin.manifest, wasm: plugin.wasm,
                project: PluginProjectRef(id: project.id, name: project.name),
                grants: Set(approval.capabilities), actions: actions(project))
            hostsByKey[key] = host
            await host.activate()
        }
    }

    // ponytail: polls every 500 ms and diffs, because agent state mixes ObservableObject
    // and @Observable sources; switch to change notifications if the rebuild shows up in profiles.
    private func startSnapshotLoop() {
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pushChangedSnapshots()
                try? await Task.sleep(for: .milliseconds(500))
            }
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
                guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw PluginManifestError.invalidEntry(manifest.entry)
                }
                let wasm = try Data(contentsOf: entry)
                found.append(Plugin(
                    folder: folder, manifest: manifest, wasm: [UInt8](wasm),
                    hash: PluginTrust.hash(manifest: manifestData, wasm: wasm)))
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
