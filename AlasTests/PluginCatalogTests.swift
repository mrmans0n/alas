import Foundation
import Testing
@testable import Alas

struct PluginCatalogTests {
    static func version(_ version: String, api: Int = 4, hash: String = "h", entry: Bool = true) -> PluginCatalogIndex.Version {
        let base = URL(string: "https://example.com/\(version)/")!
        return PluginCatalogIndex.Version(
            version: version, api: api, capabilities: [], manifest: base.appending(path: "plugin.json"),
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

    struct RowCase: Sendable, CustomTestStringConvertible {
        let name: String
        let installed: (folder: String, version: String, hash: String)?
        let expected: PluginCatalogRow
        var linked = false
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
    ])
    func rowStateFollowsWhatIsInstalled(_ c: RowCase) throws {
        let entry = Self.entry([Self.version("0.3.0", hash: "new"), Self.version("0.2.0", hash: "old")])
        let installed = try c.installed.map { try Self.installed(folder: $0.folder, version: $0.version, hash: $0.hash, linked: c.linked) }
        #expect(PluginCatalogRow(entry: entry, installed: installed) == c.expected)
    }

    @MainActor
    @Test func installVerifiesTheHashBeforeReplacingTheFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginCatalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = Data(#"{"id":"io.x.p","name":"P","version":"0.3.0","api":4,"entry":"plugin.js"}"#.utf8)
        let script = Data("globalThis.handle = () => {};".utf8)
        let files = [URL(string: "https://example.com/0.3.0/plugin.json")!: manifest, URL(string: "https://example.com/0.3.0/plugin.js")!: script]
        let catalog = PluginCatalog(fetch: { url in try #require(files[url]) })
        let suite = "PluginCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults),
            projects: { [] }, actions: { _ in .inert }, catalog: catalog)
        // A staging folder symlinked elsewhere must not lead install to clean up inside its target.
        let elsewhere = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere.appending(path: "io.x.p"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appending(path: "io.x.p/keep"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: ".staging"), withDestinationURL: elsewhere)
        await manager.reload()

        let failure = await manager.install(Self.entry([Self.version("0.3.0", hash: "wrong")]), Self.version("0.3.0", hash: "wrong"))
        #expect(failure == PluginCatalogError.hashMismatch.description)
        #expect(manager.plugins.isEmpty)

        let hash = PluginTrust.hash(manifest: manifest, entry: script)
        #expect(await manager.install(Self.entry([Self.version("0.3.0", hash: hash)]), Self.version("0.3.0", hash: hash)) == nil)
        let plugin = try #require(manager.plugin(id: "io.x.p"))
        #expect(plugin.folder.lastPathComponent == "io.x.p" && plugin.hash == hash)
        #expect(!manager.isApproved(plugin))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".staging/io.x.p").path))
        #expect(FileManager.default.fileExists(atPath: elsewhere.appending(path: "io.x.p/keep").path))

        // Edited after the scan the row came from: no longer the catalog's files, so Remove keeps them.
        try Data("globalThis.handle = () => { /* mine */ };".utf8).write(to: plugin.folder.appending(path: "plugin.js"))
        await manager.uninstall(plugin)
        #expect(FileManager.default.fileExists(atPath: plugin.folder.appending(path: "plugin.js").path))
    }

    /// A folder at `Plugins/<id>` the catalog did not put there, even a broken one, is the user's.
    @MainActor
    @Test func installNeverReplacesAFolderTheCatalogDoesNotOwn() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginCatalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = root.appending(path: "io.x.p")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: mine.appending(path: "plugin.json"))
        let manifest = Data(#"{"id":"io.x.p","name":"P","version":"0.3.0","api":4,"entry":"plugin.js"}"#.utf8)
        let script = Data("globalThis.handle = () => {};".utf8)
        let files = [URL(string: "https://example.com/0.3.0/plugin.json")!: manifest, URL(string: "https://example.com/0.3.0/plugin.js")!: script]
        let suite = "PluginCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PluginManager(
            directory: root, approvals: PluginApprovalStore(defaults: defaults), projects: { [] }, actions: { _ in .inert },
            catalog: PluginCatalog(fetch: { url in try #require(files[url]) }))
        await manager.reload()

        let version = Self.version("0.3.0", hash: PluginTrust.hash(manifest: manifest, entry: script))
        #expect(await manager.install(Self.entry([version]), version) == PluginCatalogError.installedLocally.description)
        #expect(try Data(contentsOf: mine.appending(path: "plugin.json")) == Data("{ not json".utf8))
    }
}
