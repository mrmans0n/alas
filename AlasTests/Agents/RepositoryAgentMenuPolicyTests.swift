import Foundation
import Testing
@testable import Alas

@Suite("Repository agent menu policy")
struct RepositoryAgentMenuPolicyTests {
    @Test("ACP menu intersects host availability with the ACP launch catalog")
    func acpMenuIsIntersectionOfHostAvailabilityAndLaunchCatalog() {
        let available = [
            agent(id: "claude"),
            agent(id: "custom")
        ]

        #expect(RepositoryAgentMenuPolicy.acpAgents(from: available).map(\.id) == ["claude"])
    }

    @Test("direct menu preserves host availability order")
    func directMenuPreservesHostAvailabilityOrder() {
        let available = [
            agent(id: "custom"),
            agent(id: "claude")
        ]

        #expect(RepositoryAgentMenuPolicy.directAgents(from: available).map(\.id) == ["custom", "claude"])
    }

    private func agent(id: String) -> AgentDefinition {
        AgentDefinition(
            id: id,
            displayName: id,
            binary: id,
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
