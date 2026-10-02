import Foundation
import Testing
@testable import Alas

struct PluginManagerDiscoveryTests {
    @Test func invalidAndDuplicateFoldersAreReportedAndNotLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ folder: String, id: String, script: Bool = true, entry: String = "plugin.js") throws {
            let dir = root.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"id":"\#(id)","name":"N","version":"1","api":4,"entry":"\#(entry)"}"#.utf8)
                .write(to: dir.appending(path: "plugin.json"))
            if script { try Data([0]).write(to: dir.appending(path: "plugin.js")) }
        }
        try install("good", id: "io.x.good")
        // A dot-folder is a plugin like any other; only the catalog's staging folder is skipped.
        try install(".dotted", id: "io.x.dotted")
        try install(".staging", id: "io.x.staged")
        // Refused by its size, before it is read.
        try install("too-big", id: "io.x.toobig", script: false)
        try Data(count: PluginLimits().maxSourceBytes + 1).write(to: root.appending(path: "too-big/plugin.js"))
        try install("no-script", id: "io.x.noscript", script: false)
        try install("dup-a", id: "io.x.dup")
        try install("dup-b", id: "io.x.dup")
        // A local copy shadows the catalog's copy in the folder named after the id.
        try install("io.x.shadowed", id: "io.x.shadowed")
        try install("my-build", id: "io.x.shadowed")
        // An entry symlinked to a file outside its folder escapes the folder.
        try install("linked-out", id: "io.x.linkedout", script: false)
        let outside = root.appending(path: "outside.js")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked-out/plugin.js"), withDestinationURL: outside)
        // So does an entry that reaches its file through a symlinked directory.
        try install("linked-dir", id: "io.x.linkeddir", script: false, entry: "link/plugin.js")
        let outsideDir = FileManager.default.temporaryDirectory.appending(path: "PluginDiscoveryOutside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data([0]).write(to: outsideDir.appending(path: "plugin.js"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked-dir/link"), withDestinationURL: outsideDir)

        let result = PluginManager.discover(in: root)

        #expect(result.plugins.map(\.folder.lastPathComponent) == [".dotted", "good", "my-build"])
        #expect(Set(result.invalid.map(\.folder.lastPathComponent)) == ["no-script", "dup-a", "dup-b", "linked-out", "linked-dir", "io.x.shadowed", "too-big"])
    }

    /// The user approves what a row showed. If the files changed and were rescanned since, that
    /// approval must not start the old bytes or leave the new ones looking approved.
    @MainActor
    @Test func approvingAStaleRowStartsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginStaleApproval-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PluginManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func install(_ source: Data) throws {
            let dir = root.appending(path: "p")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"id":"io.x.p","name":"P","version":"1","api":4,"entry":"plugin.js"}"#.utf8)
                .write(to: dir.appending(path: "plugin.json"))
            try source.write(to: dir.appending(path: "plugin.js"))
        }
        let activate = #"{"jsonrpc":"2.0","id":0,"result":{}}"#
        let project = ProjectConfig(id: "proj", name: "Project", path: "/tmp/proj", color: "blue", addedAt: Date())
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults),
            projects: { [project] },
            actions: { _ in .inert })

        try install(PluginJSFixture.source([[.send(activate)]]))
        await manager.reload()
        let staleRow = try #require(manager.plugins.first)

        try install(PluginJSFixture.source([[.send(activate), .send(activate)]]))
        await manager.reload()
        await manager.approve(staleRow)

        #expect(manager.hostsByKey.isEmpty)
        #expect(manager.plugins.first.map(manager.isApproved) == false)
    }

    @MainActor
    final class ProjectList {
        var projects: [ProjectConfig]
        init(_ projects: [ProjectConfig]) { self.projects = projects }
    }

    static func project(_ id: String) -> ProjectConfig {
        ProjectConfig(id: id, name: id, path: "/tmp/\(id)", color: "blue", addedAt: Date())
    }

    @MainActor
    func approvedManager(projects: ProjectList) async throws -> (PluginManager, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginReconcile-\(UUID().uuidString)")
        let suite = "PluginManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let dir = root.appending(path: "p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"id":"io.x.p","name":"P","version":"1","api":4,"entry":"plugin.js"}"#.utf8)
            .write(to: dir.appending(path: "plugin.json"))
        try PluginJSFixture.source([[.send(#"{"jsonrpc":"2.0","id":0,"result":{}}"#)]])
            .write(to: dir.appending(path: "plugin.js"))
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults),
            projects: { projects.projects }, actions: { _ in .inert })
        await manager.reload()
        await manager.approve(try #require(manager.plugins.first))
        return (manager, {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @MainActor
    @Test func reconcileFollowsTheProjectList() async throws {
        let projects = ProjectList([Self.project("a")])
        let (manager, cleanup) = try await approvedManager(projects: projects)
        defer { cleanup() }
        let first = try #require(manager.host(pluginID: "io.x.p", projectID: "a"))
        projects.projects = [Self.project("b")]
        await manager.reconcile()
        #expect(manager.hostsByKey.keys.map(\.projectID) == ["b"])
        #expect(first.state == .stopped)
        await manager.shutdown()
    }

    @MainActor
    @Test func disablingAPluginStopsItsHostsAndEnablingRestartsThem() async throws {
        let projects = ProjectList([Self.project("a")])
        let (manager, cleanup) = try await approvedManager(projects: projects)
        defer { cleanup() }
        let plugin = try #require(manager.plugins.first)
        await manager.setEnabled(plugin, false)
        #expect(manager.hostsByKey.isEmpty)
        #expect(!manager.isEnabled(plugin))
        await manager.reconcile()
        #expect(manager.hostsByKey.isEmpty, "reconcile must not restart a disabled plugin")
        await manager.setEnabled(plugin, true)
        #expect(manager.host(pluginID: "io.x.p", projectID: "a")?.state == .active)
        await manager.shutdown()
    }

    @MainActor
    @Test func aShutDownManagerDoesNotRestartHosts() async throws {
        let projects = ProjectList([Self.project("a")])
        let (manager, cleanup) = try await approvedManager(projects: projects)
        defer { cleanup() }
        await manager.shutdown()
        await manager.reconcile()
        await manager.reload()
        #expect(manager.hostsByKey.isEmpty)
    }

    /// Enabling from a settings row that a rescan has since replaced must not start the old bytes,
    /// whose approval is still stored under the old hash.
    @MainActor
    @Test func enablingAStaleRowDoesNotStartTheReplacedPlugin() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginStaleEnable-\(UUID().uuidString)")
        let suite = "PluginManagerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        func install(_ source: Data) throws {
            let dir = root.appending(path: "p")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"id":"io.x.p","name":"P","version":"1","api":4,"entry":"plugin.js"}"#.utf8)
                .write(to: dir.appending(path: "plugin.json"))
            try source.write(to: dir.appending(path: "plugin.js"))
        }
        let activate = #"{"jsonrpc":"2.0","id":0,"result":{}}"#
        let projects = ProjectList([Self.project("a")])
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults),
            projects: { projects.projects }, actions: { _ in .inert })

        try install(PluginJSFixture.source([[.send(activate)]]))
        await manager.reload()
        let staleRow = try #require(manager.plugins.first)
        await manager.approve(staleRow)
        await manager.setEnabled(staleRow, false)

        try install(PluginJSFixture.source([[.send(activate), .send(activate)]]))
        await manager.reload()
        await manager.setEnabled(staleRow, true)

        #expect(manager.hostsByKey.isEmpty)
        await manager.shutdown()
    }
}
