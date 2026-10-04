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
}
