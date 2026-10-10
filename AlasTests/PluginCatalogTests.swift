import Foundation
import Testing
@testable import Alas

struct PluginCatalogTests {
    static func version(
        _ version: String, api: Int = 4, hash: String = "h", entry: Bool = true, manifest: String = "plugin",
        capabilities: [String] = []
    ) -> PluginCatalogIndex.Version {
        let base = URL(string: "https://example.com/\(version)/")!
        return PluginCatalogIndex.Version(
            version: version, api: api, capabilities: capabilities, manifest: base.appending(path: "\(manifest).json"),
            entry: entry ? base.appending(path: "plugin.js") : nil, hash: hash)
    }

    static func entry(_ versions: [PluginCatalogIndex.Version]) -> PluginCatalogIndex.Entry {
        PluginCatalogIndex.Entry(id: "io.x.p", name: "P", summary: nil, homepage: nil, versions: versions)
    }

    static func installed(folder: String = "io.x.p", version: String, hash: String, linked: Bool = false) throws -> PluginManager.Plugin {
        let manifest = try PluginManifest.parse(Data(#"{"id":"io.x.p","name":"P","version":"\#(version)","api":4,"entry":"plugin.js"}"#.utf8))
        return PluginManager.Plugin(folder: URL(filePath: "/tmp/Plugins/\(folder)"), manifest: manifest, source: Data(), hash: hash, isLinked: linked)
    }

    /// Numeric, not lexical; other APIs and entries without a script (Wasm-era releases) are skipped.
    @Test func theNewestCompatibleVersionWins() {
        let entry = Self.entry([
            Self.version("0.2.0"), Self.version("0.10.0"), Self.version("0.11.0", api: 3), Self.version("0.12.0", entry: false),
        ])
        #expect(entry.newestCompatible?.version == "0.10.0")
        #expect(Self.entry([Self.version("1.0.0", api: 3)]).newestCompatible == nil)
    }

    /// Updates listed from the last index must not vanish while a refresh runs or after it fails.
    @MainActor
    @Test func aFailedRefreshKeepsTheLastLoadedIndex() async throws {
        final class Responses: @unchecked Sendable { var data: [Data] = [] }
        let responses = Responses()
        responses.data = [Data(#"{"format":1,"plugins":[]}"#.utf8)]
        let catalog = PluginCatalog(fetch: { _ in
            guard !responses.data.isEmpty else { throw URLError(.notConnectedToInternet) }
            return responses.data.removeFirst()
        })

        await catalog.refresh()
        let loaded = try #require(catalog.index)
        await catalog.refresh(force: true)

        guard case .failed = catalog.state else {
            Issue.record("expected the refresh to fail")
            return
        }
        #expect(catalog.index == loaded)
    }

    struct RowCase: Sendable, CustomTestStringConvertible {
        let name: String
        let installed: (folder: String, version: String, hash: String)?
        let expected: PluginCatalogRow
        var linked = false
        var quarantined = false
        var testDescription: String { name }
    }

    @Test(arguments: [
        RowCase(name: "not installed", installed: nil, expected: .install(version("0.3.0", hash: "new"))),
        RowCase(name: "current", installed: ("io.x.p", "0.3.0", "new"), expected: .installed),
        RowCase(name: "older from the catalog", installed: ("io.x.p", "0.2.0", "old"), expected: .update(version("0.3.0", hash: "new"))),
        RowCase(name: "built locally into another folder", installed: ("kanban", "0.3.0", "new"), expected: .installedLocally),
        RowCase(name: "edited in place", installed: ("io.x.p", "0.2.0", "edited"), expected: .installedLocally),
        // Removing it would delete the symlink's target, perhaps someone's checkout.
        RowCase(name: "symlinked in under the id", installed: ("io.x.p", "0.3.0", "new"), expected: .installedLocally, linked: true),
        RowCase(name: "local copies quarantined as duplicates", installed: nil, expected: .installedLocally, quarantined: true),
        RowCase(name: "release with files added", installed: ("io.x.p", "0.2.0", "old"), expected: .installedLocally, quarantined: true),
    ])
    func rowStateFollowsWhatIsInstalled(_ c: RowCase) throws {
        let entry = Self.entry([Self.version("0.3.0", hash: "new"), Self.version("0.2.0", hash: "old")])
        let installed = try c.installed.map { try Self.installed(folder: $0.folder, version: $0.version, hash: $0.hash, linked: c.linked) }
        #expect(PluginCatalogRow(entry: entry, installed: installed, quarantined: c.quarantined) == c.expected)
    }

    /// A plugins folder and a manager whose catalog serves one valid 0.3.0 release of `io.x.p`.
    @MainActor
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginCatalog-\(UUID().uuidString)")
        let suite = "PluginCatalogTests.\(UUID().uuidString)"
        let release: PluginCatalogIndex.Version
        let manager: PluginManager
        let script = Data("globalThis.handle = () => {};".utf8)

        /// `extra` is spliced into the release's manifest after `entry`, asking for `capabilities`.
        init(projects: [ProjectConfig] = [], api: Int = 4, extra: String = "", capabilities: [String] = []) throws {
            let manifest = Data(#"{"id":"io.x.p","name":"P","version":"0.3.0","api":\#(api),"entry":"plugin.js"\#(extra)}"#.utf8)
            let base = "https://example.com/0.3.0/"
            let files = [
                URL(string: base + "plugin.json")!: manifest, URL(string: base + "plugin.js")!: self.script,
                URL(string: base + "bad.json")!: Data("{".utf8),
            ]
            release = PluginCatalogTests.version(
                "0.3.0", api: api, hash: PluginTrust.hash(manifest: manifest, entry: script), capabilities: capabilities)
            manager = PluginManager(
                directory: root, approvals: PluginApprovalStore(defaults: try #require(UserDefaults(suiteName: suite))),
                projects: { projects }, actions: { _ in .inert }, catalog: PluginCatalog(fetch: { url in try #require(files[url]) }))
        }

        func install(_ version: PluginCatalogIndex.Version? = nil) async -> String? {
            let version = version ?? release
            return await manager.install(PluginCatalogTests.entry([version]), version)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: manager.stagingDirectory)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    @MainActor
    @Test func installVerifiesTheHashThenInstallsUnapproved() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        await f.manager.reload()

        #expect(await f.install(Self.version("0.3.0", hash: "wrong")) == PluginCatalogError.hashMismatch.description)
        #expect(f.manager.plugins.isEmpty)
        // A release whose files match its hash but whose manifest is invalid says why.
        let failure = await f.install(Self.version("0.3.0", hash: PluginTrust.hash(manifest: Data("{".utf8), entry: f.script), manifest: "bad"))
        #expect(failure == PluginCatalogError.invalidDownload(PluginManifestError.malformed.description).description)

        #expect(await f.install() == nil)
        let plugin = try #require(f.manager.plugin(id: "io.x.p"))
        #expect(plugin.folder.lastPathComponent == "io.x.p" && plugin.hash == f.release.hash)
        #expect(!f.manager.isApproved(plugin))
        #expect(!FileManager.default.fileExists(atPath: f.manager.stagingDirectory.appending(path: "io.x.p").path))
        #expect(!f.manager.catalogPathIsTaken(id: "io.x.p"))
    }

    /// An entry written as `./plugin.js` or in a subfolder, and a web page beside it (API 12), are still exactly the release.
    @Test(arguments: [("plugin.js", nil as String?), ("./plugin.js", nil), ("dist/plugin.js", nil), ("plugin.js", "web/ui.js")])
    func aReleaseFolderIsCatalogOwnedWhateverTheEntryPath(entry: String, web: String?) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PluginCatalog-\(UUID().uuidString)/io.x.p")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        for path in [entry] + (web.map { [$0] } ?? []) {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        try Data().write(to: folder.appending(path: "plugin.json"))
        let page = web.map { #","web":"\#($0)","contributes":{"tabs":[{"id":"w","title":"W","kind":"web"}]}"# } ?? ""
        let manifest = try PluginManifest.parse(
            Data(#"{"id":"io.x.p","name":"P","version":"1","api":\#(web == nil ? 4 : 12),"entry":"\#(entry)"\#(page)}"#.utf8))
        let plugin = PluginManager.Plugin(folder: folder, manifest: manifest, source: Data(), hash: "h")
        #expect(PluginManager.isCatalogOwned(plugin))
        try Data().write(to: folder.appending(path: "extra.txt"))
        #expect(!PluginManager.isCatalogOwned(plugin))
    }

    /// Installing one plugin leaves every other running plugin, and its state, alone.
    @MainActor
    @Test func installKeepsOtherPluginsRunning() async throws {
        let project = ProjectConfig(id: "proj", name: "Project", path: "/tmp/proj", color: "blue", addedAt: Date())
        let f = try Fixture(projects: [project])
        defer { f.cleanUp() }
        let other = f.root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(#"{"id":"io.x.other","name":"O","version":"1","api":4,"entry":"plugin.js"}"#.utf8).write(to: other.appending(path: "plugin.json"))
        try PluginJSFixture.source([[.send(#"{"jsonrpc":"2.0","id":0,"result":{}}"#)]]).write(to: other.appending(path: "plugin.js"))
        await f.manager.reload()
        await f.manager.approve(try #require(f.manager.plugin(id: "io.x.other")))
        let running = try #require(f.manager.host(pluginID: "io.x.other", projectID: "proj"))

        #expect(await f.install() == nil)
        #expect(f.manager.host(pluginID: "io.x.other", projectID: "proj") === running)
        await f.manager.shutdown()
    }

    /// Updating an approved 0.2.0 that asks for nothing new stays approved without asking; one that asks for more
    /// installs, approved, only if the user accepts, and otherwise leaves 0.2.0 approved in place.
    @MainActor
    @Test(arguments: [
        (extra: "", capabilities: [String](), answer: nil as Bool?, installed: "0.3.0"),
        (extra: #","capabilities":["network"],"network":["a.com"]"#, capabilities: ["network"], answer: false, installed: "0.2.0"),
        (extra: #","capabilities":["network"],"network":["a.com"]"#, capabilities: ["network"], answer: true, installed: "0.3.0"),
    ])
    func updatingAnApprovedPluginAsksOnlyForNewPermissions(
        extra: String, capabilities: [String], answer: Bool?, installed: String
    ) async throws {
        let f = try Fixture(api: 5, extra: extra, capabilities: capabilities)
        defer { f.cleanUp() }
        let folder = f.root.appending(path: "io.x.p")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oldManifest = Data(#"{"id":"io.x.p","name":"P","version":"0.2.0","api":4,"entry":"plugin.js"}"#.utf8)
        try oldManifest.write(to: folder.appending(path: "plugin.json"))
        try f.script.write(to: folder.appending(path: "plugin.js"))
        await f.manager.reload()
        await f.manager.approve(try #require(f.manager.plugin(id: "io.x.p")))
        let old = Self.version("0.2.0", hash: PluginTrust.hash(manifest: oldManifest, entry: f.script))

        var asked: [String]?
        #expect(await f.manager.install(Self.entry([f.release, old]), f.release) { _, added in
            asked = added
            return answer ?? false
        } == nil)
        #expect(asked == answer.map { _ in [PluginCapability.network.summary, "Make web requests to a.com"] })
        let plugin = try #require(f.manager.plugin(id: "io.x.p"))
        #expect(plugin.manifest.version == installed)
        #expect(f.manager.isApproved(plugin))
    }

    /// A symlinked staging folder must not lead install to clean up inside its target.
    @MainActor
    @Test func installNeverCleansUpThroughASymlinkedStagingFolder() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let elsewhere = f.root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere.appending(path: "io.x.p"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appending(path: "io.x.p/keep"))
        try FileManager.default.createSymbolicLink(at: f.manager.stagingDirectory, withDestinationURL: elsewhere)
        await f.manager.reload()

        #expect(await f.install() == nil)
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "io.x.p/keep").path))
    }

    /// Edited after the scan the row came from: no longer the catalog's files, so Remove keeps them and says so.
    @MainActor
    @Test func removeKeepsFilesChangedSinceTheScan() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        await f.manager.reload()
        #expect(await f.install() == nil)
        let plugin = try #require(f.manager.plugin(id: "io.x.p"))

        try Data("globalThis.handle = () => { /* mine */ };".utf8).write(to: plugin.folder.appending(path: "plugin.js"))
        #expect(await f.manager.uninstall(plugin) == PluginCatalogError.installedLocally.description)
        #expect(FileManager.default.fileExists(atPath: plugin.folder.appending(path: "plugin.js").path))
    }

    /// A file someone added next to the release makes the folder theirs: Remove keeps it.
    @MainActor
    @Test func removeKeepsAFolderWithAddedFiles() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        await f.manager.reload()
        #expect(await f.install() == nil)
        let plugin = try #require(f.manager.plugin(id: "io.x.p"))

        try Data("notes".utf8).write(to: plugin.folder.appending(path: "notes.txt"))
        #expect(await f.manager.uninstall(plugin) == PluginCatalogError.installedLocally.description)
        #expect(FileManager.default.fileExists(atPath: plugin.folder.appending(path: "notes.txt").path))
        // Once rescanned, the row offers neither Remove nor Update for it.
        await f.manager.reload()
        #expect(f.manager.catalogPathIsTaken(id: "io.x.p"))
    }

    /// A folder at `Plugins/<id>` the catalog did not put there, even a broken one, is the user's.
    @MainActor
    @Test func installNeverReplacesAFolderTheCatalogDoesNotOwn() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let mine = f.root.appending(path: "io.x.p")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: mine.appending(path: "plugin.json"))
        await f.manager.reload()

        #expect(await f.install() == PluginCatalogError.installedLocally.description)
        #expect(try Data(contentsOf: mine.appending(path: "plugin.json")) == Data("{ not json".utf8))
    }

    /// A hand-built copy in another folder wins, so the catalog does not install a shadowed duplicate; nor does it
    /// add a third copy next to two local ones quarantined as duplicates.
    @MainActor
    /// A half-built one, with a manifest but no script yet, counts too.
    @Test(arguments: [(["my-build"], true), (["build-a", "build-b"], true), (["half-built"], false)])
    func installStepsAsideForLocalCopiesElsewhere(folders: [String], withScript: Bool) async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        for folder in folders {
            let local = f.root.appending(path: folder)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try Data(#"{"id":"io.x.p","name":"P","version":"9","api":4,"entry":"plugin.js"}"#.utf8).write(to: local.appending(path: "plugin.json"))
            if withScript { try f.script.write(to: local.appending(path: "plugin.js")) }
        }
        await f.manager.reload()

        #expect(await f.install() == PluginCatalogError.installedLocally.description)
        #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "io.x.p").path))
    }
}
