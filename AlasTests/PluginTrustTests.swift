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
}
