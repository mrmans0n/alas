import Testing
@testable import Alas

@Suite("ACP managed adapter descriptors")
struct ACPManagedAdapterDescriptorTests {
    @Test("catalog contains the adapters Alas manages")
    func catalogContainsManagedAdapters() throws {
        let claude = try #require(ACPManagedAdapterDescriptor.descriptor(for: "claude"))
        #expect(claude.packageName == "@agentclientprotocol/claude-agent-acp")
        #expect(claude.binaryName == "claude-agent-acp")
        #expect(claude.legacyPackageNames == ["@zed-industries/claude-code-acp"])

        let codex = try #require(ACPManagedAdapterDescriptor.descriptor(for: "codex"))
        #expect(codex.packageName == "@agentclientprotocol/codex-acp")
        #expect(codex.binaryName == "codex-acp")
        #expect(codex.legacyPackageNames == ["@zed-industries/codex-acp"])

        let pi = try #require(ACPManagedAdapterDescriptor.descriptor(for: "pi"))
        #expect(pi.packageName == "pi-acp")
        #expect(pi.binaryName == "pi-acp")
        #expect(pi.legacyPackageNames.isEmpty)
    }

    @Test("unmanaged agents have no descriptor")
    func unmanagedAgentsHaveNoDescriptor() {
        for agentID in ["gemini", "opencode", "cursor-agent", "copilot"] {
            #expect(ACPManagedAdapterDescriptor.descriptor(for: agentID) == nil)
        }
    }

    @Test("launch catalog uses descriptor package and binary names")
    func launchCatalogMatchesDescriptors() throws {
        for agentID in ["claude", "codex", "pi"] {
            let descriptor = try #require(ACPManagedAdapterDescriptor.descriptor(for: agentID))
            let spec = try #require(ACPLaunchCatalog.spec(for: agentID))
            #expect(spec.command == descriptor.binaryName)
            #expect(spec.npmPackageName == descriptor.packageName)
        }
    }
}
