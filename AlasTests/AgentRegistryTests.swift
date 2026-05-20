import Testing
@testable import Alas

struct AgentRegistryTests {
    private struct StubInstaller: AgentInstaller {
        let agent: AgentKind

        func installState() -> InstallState { .notInstalled }
        func install() async throws {}
        func uninstall() throws {}
    }

    @Test func defaultRegistryEnumeratesBuiltinsInCatalogOrder() {
        let r = AgentRegistry(
            builtinState: [:],
            customs: [],
            installedIds: []
        )
        let ids = r.agents.map(\.id)
        #expect(ids == AgentBuiltins.catalog.map(\.id))
    }

    @Test func builtinStateAppliesEnabledFlag() {
        let r = AgentRegistry(
            builtinState: ["codex": BuiltinAgentState(isEnabled: false, binaryOverride: nil)],
            customs: [],
            installedIds: []
        )
        let codex = r.agents.first(where: { $0.id == "codex" })!
        #expect(codex.isEnabled == false)
    }

    @Test func builtinStateAppliesBinaryOverride() {
        let r = AgentRegistry(
            builtinState: ["claude": BuiltinAgentState(isEnabled: true, binaryOverride: "/opt/local/bin/claude")],
            customs: [],
            installedIds: ["claude"]
        )
        let claude = r.agents.first(where: { $0.id == "claude" })!
        #expect(claude.binaryOverride == "/opt/local/bin/claude")
        #expect(claude.resolvedBinary == "/opt/local/bin/claude")
    }

    @Test func customsAppendAfterBuiltins() {
        let custom = AgentDefinition(
            id: "custom-uuid",
            displayName: "My agent",
            binary: "~/bin/agent",
            binaryOverride: nil,
            promptModeArgs: ["-p"],
            bypassPermissionsFlag: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
        let r = AgentRegistry(builtinState: [:], customs: [custom], installedIds: [])
        let ids = r.agents.map(\.id)
        #expect(ids.last == "custom-uuid")
        #expect(ids.count == 8)
    }

    @Test func installedFiltersToDetectedAgentsAcrossBuiltinsAndCustoms() {
        let custom = AgentDefinition(
            id: "c1", displayName: "C", binary: "c-bin",
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let r = AgentRegistry(
            builtinState: [:],
            customs: [custom],
            installedIds: ["claude", "c1"]
        )
        let installed = r.installed().map(\.id)
        #expect(Set(installed) == Set(["claude", "c1"]))
    }

    @Test func enabledRequiresInstalledAndEnabled() {
        let r = AgentRegistry(
            builtinState: [
                "claude": BuiltinAgentState(isEnabled: true, binaryOverride: nil),
                "codex":  BuiltinAgentState(isEnabled: false, binaryOverride: nil),
            ],
            customs: [],
            installedIds: ["claude", "codex", "pi"] // codex installed but disabled, pi installed but default enabled
        )
        let enabledIds = Set(r.enabled().map(\.id))
        #expect(enabledIds == Set(["claude", "pi"]))
    }

    @Test func enabledIsEmptyWhenNothingInstalled() {
        let r = AgentRegistry(builtinState: [:], customs: [], installedIds: [])
        #expect(r.enabled().isEmpty)
    }

    @Test func customDisabledNotInEnabled() {
        let custom = AgentDefinition(
            id: "c1", displayName: "C", binary: "c-bin",
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: false, builtinLogoAssetName: nil
        )
        let r = AgentRegistry(
            builtinState: [:], customs: [custom], installedIds: ["c1"]
        )
        #expect(!r.enabled().contains(where: { $0.id == "c1" }))
    }

    @Test func unknownBuiltinIdInStateIsIgnored() {
        // Forward-compat: a config from a newer app version may contain
        // overlay entries for agents this version doesn't know. They
        // must be silently dropped, leaving the catalog unchanged.
        let r = AgentRegistry(
            builtinState: ["unknown-agent-id": BuiltinAgentState(isEnabled: false, binaryOverride: "/x")],
            customs: [],
            installedIds: []
        )
        let ids = r.agents.map(\.id)
        #expect(ids == AgentBuiltins.catalog.map(\.id))
        // Built-ins are now all disabled because nothing is installed; the
        // important assertion is that the unknown overlay didn't change the
        // set of agents (catalog identity).
        #expect(r.agents.allSatisfy { !$0.isEnabled })
    }

    @Test func unconfiguredBuiltinIsEnabledOnlyWhenInstalled() {
        let r = AgentRegistry(
            builtinState: [:],
            customs: [],
            installedIds: ["claude"] // only claude is installed
        )
        let claude = r.agents.first(where: { $0.id == "claude" })!
        let codex  = r.agents.first(where: { $0.id == "codex" })!
        #expect(claude.isEnabled == true)
        #expect(codex.isEnabled == false)
    }

    @Test func persistedEnabledBuiltinIsClampedWhenUninstalled() {
        let r = AgentRegistry(
            builtinState: ["gemini": BuiltinAgentState(isEnabled: true, binaryOverride: nil)],
            customs: [],
            installedIds: [] // gemini not installed
        )
        let gemini = r.agents.first(where: { $0.id == "gemini" })!
        #expect(gemini.isEnabled == false)
    }

    @Test func customAgentIsEnabledOnlyWhenInstalled() {
        let installed = AgentDefinition(
            id: "c-installed", displayName: "C-In", binary: "c-in",
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let missing = AgentDefinition(
            id: "c-missing", displayName: "C-Miss", binary: "c-miss",
            binaryOverride: nil, promptModeArgs: [], bypassPermissionsFlag: nil,
            isBuiltin: false, isEnabled: true, builtinLogoAssetName: nil
        )
        let r = AgentRegistry(
            builtinState: [:],
            customs: [installed, missing],
            installedIds: ["c-installed"]
        )
        #expect(r.agents.first(where: { $0.id == "c-installed" })!.isEnabled == true)
        #expect(r.agents.first(where: { $0.id == "c-missing"   })!.isEnabled == false)
    }

    @Test func defaultInstallerRegistryExposesOnlyAgentsWithInstallers() {
        let registry = AgentInstallerRegistry()

        #expect(registry.supportedAgents == [.claude, .codex, .cursor])
    }

    @Test func supportedInstallerAgentsFollowsRegisteredInstallers() {
        let registry = AgentInstallerRegistry(installers: [
            StubInstaller(agent: .gemini),
            StubInstaller(agent: .opencode),
        ])

        #expect(registry.supportedAgents == [.gemini, .opencode])
    }
}
