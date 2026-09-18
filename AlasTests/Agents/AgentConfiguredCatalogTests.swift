import Testing
@testable import Alas

struct AgentConfiguredCatalogTests {
    @Test func enabledCatalogDoesNotRequireLocalInstallation() {
        let agents = AgentConfiguredCatalog.enabled(
            builtinState: [
                "claude": .init(isEnabled: true, binaryOverride: nil),
                "codex": .init(isEnabled: false, binaryOverride: nil),
            ],
            customs: []
        )

        #expect(agents.contains { $0.id == "claude" })
        #expect(!agents.contains { $0.id == "codex" })
    }

    @Test func enabledCatalogAppendsEnabledCustomAgentsWithOverride() {
        var custom = TestAgents.custom(id: "remote-custom", binary: "custom")
        custom.binaryOverride = "~/remote/bin/custom"

        let agents = AgentConfiguredCatalog.enabled(builtinState: [:], customs: [custom])

        #expect(agents.last?.id == "remote-custom")
        #expect(agents.last?.configuredBinary == "~/remote/bin/custom")
    }
}

private enum TestAgents {
    static func custom(id: String, binary: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: id,
            binary: binary,
            binaryOverride: nil,
            promptModeArgs: [],
            bypassPermissionsFlag: nil,
            extraTerminalArgs: nil,
            isBuiltin: false,
            isEnabled: true,
            builtinLogoAssetName: nil
        )
    }
}
