import Foundation
import Testing
@testable import Alas

struct PluginTrustTests {
    @Test func changingTheScriptRequiresApprovalAgain() throws {
        let suite = "PluginTrustTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PluginApprovalStore(defaults: defaults)
        let manifest = Data("{}".utf8)
        let approved = PluginTrust.hash(manifest: manifest, entry: Data([0, 1]))
        store.approve(PluginApproval(id: "io.x.p", hash: approved, capabilities: [.workspaceRead]))

        #expect(store.approval(id: "io.x.p", hash: approved)?.capabilities == [.workspaceRead])
        #expect(store.approval(id: "io.x.p", hash: PluginTrust.hash(manifest: manifest, entry: Data([0, 2]))) == nil)
    }

    /// v1 stays byte-for-byte what it was, so existing approvals and catalog records keep matching. v2 frames each
    /// file with its length, so bytes moved between the entry and the page change the hash.
    @Test func aWebPageMovesTheHashToFramedV2AndOthersKeepV1() {
        let manifest = Data("{}".utf8)
        #expect(PluginTrust.hash(manifest: manifest, entry: Data("a".utf8))
            == "6e8248f7fc18935c12f797ac29956a8a81849156081446a447d560bcad2ad57e")
        #expect(PluginTrust.hash(manifest: manifest, entry: Data("ab".utf8), web: Data("c".utf8))
            != PluginTrust.hash(manifest: manifest, entry: Data("a".utf8), web: Data("bc".utf8)))
        #expect(PluginTrust.hash(manifest: manifest, entry: Data("a".utf8), web: Data())
            != PluginTrust.hash(manifest: manifest, entry: Data("a".utf8)))
    }

    struct PermissionCase: Sendable, CustomTestStringConvertible {
        let name: String
        var caps = #""network","process.exec","files.read""#
        var network = #""a.com","b.com""#
        var process = #""command":["git","status"]"#
        var secretHosts = #""a.com""#
        var extra = ""
        /// The approved version's process; the other fields of the approved version are the defaults.
        var oldProcess = #""command":["git","status"]"#
        let added: [String]
        var testDescription: String { name }

        func manifest() throws -> PluginManifest {
            try PluginManifest.parse(Data(#"""
                {"id":"io.x.p","name":"P","version":"1","api":12,"entry":"p.js","capabilities":[\#(caps)],\#
                "network":[\#(network)],"processes":[{"id":"s",\#(process)}],\#
                "settings":[{"key":"t","title":"Token","type":"secret","hosts":[\#(secretHosts)]}]\#(extra)}
                """#.utf8))
        }
    }

    /// Everything the approval sheet discloses counts; keeping or dropping permissions adds nothing.
    @Test(arguments: [
        PermissionCase(name: "unchanged", added: []),
        PermissionCase(name: "fewer", caps: #""network","process.exec""#, network: #""a.com""#, added: []),
        PermissionCase(name: "new host", network: #""a.com","b.com","c.com""#, added: ["Make web requests to c.com"]),
        PermissionCase(name: "new capability", caps: #""network","process.exec","files.read","files.write""#,
                       added: [PluginCapability.filesWrite.summary]),
        PermissionCase(name: "appends arguments", process: #""command":["git","status"],"appendArgs":true"#, added: ["Run git status …"]),
        PermissionCase(name: "narrows a command that took arguments", process: #""command":["git","status"],"appendArgs":true"#,
                       oldProcess: #""command":["git"],"appendArgs":true"#, added: []),
        PermissionCase(name: "secret sent to another host", secretHosts: #""a.com","b.com""#, added: ["Use Token with b.com"]),
        PermissionCase(name: "remote and web", extra: #","remote":true,"web":"ui.js","contributes":{"tabs":[{"id":"w","title":"W","kind":"web"}]}"#,
                       added: ["Act in projects on SSH hosts, as your user there", "Show its own web content, with no network access"]),
    ])
    func anUpdateAsksOnlyForWhatIsNew(_ c: PermissionCase) throws {
        let old = try PermissionCase(name: "old", process: c.oldProcess, added: []).manifest()
        #expect(PluginPermissionChange.added(approved: old, granted: old.capabilities, update: try c.manifest()) == c.added)
    }

    /// From API 15 a page may show images from the plugin's hosts, so the update says so even with nothing else new;
    /// dropping or reordering those hosts asks nothing.
    @Test func anAPI15PageAsksForTheHostsItShowsImagesFrom() throws {
        func manifest(api: Int, network: String = #""a.com""#) throws -> PluginManifest {
            try PluginManifest.parse(Data(#"{"id":"io.x.p","name":"P","version":"1","api":\#(api),"entry":"p.js","capabilities":["network"],"network":[\#(network)],"web":"ui.js","contributes":{"tabs":[{"id":"w","title":"W","kind":"web"}]}}"#.utf8))
        }
        let old = try manifest(api: 12)
        #expect(PluginPermissionChange.added(approved: old, granted: old.capabilities, update: try manifest(api: 15))
            == ["Show its own web content, with images from a.com"])
        let approved = try manifest(api: 15, network: #""a.com","b.com""#)
        for network in [#""b.com""#, #""b.com","a.com""#] {
            #expect(PluginPermissionChange.added(
                approved: approved, granted: approved.capabilities, update: try manifest(api: 15, network: network)).isEmpty)
        }
    }
}
