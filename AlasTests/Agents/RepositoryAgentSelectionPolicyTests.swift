import Testing
@testable import Alas

struct RepositoryAgentSelectionPolicyTests {
    @Test func selectedAgentMustExistOnCurrentHost() {
        let codex = agent(id: "codex", binary: "codex")

        #expect(
            RepositoryAgentSelectionPolicy.selection(
                selectedID: "claude",
                availability: .available([codex])
            ) == .selectionUnavailable
        )
        #expect(
            RepositoryAgentSelectionPolicy.selection(
                selectedID: "codex",
                availability: .available([codex])
            ).agent?.id == "codex"
        )
    }

    @Test func loadingFailureAndEmptyRemainDistinct() {
        #expect(RepositoryAgentSelectionPolicy.selection(selectedID: "claude", availability: .loading) == .loading)
        #expect(RepositoryAgentSelectionPolicy.selection(selectedID: "claude", availability: .available([])) == .empty)
        #expect(RepositoryAgentSelectionPolicy.selection(selectedID: "claude", availability: .failed("offline")) == .failed("offline"))
    }

    private func agent(id: String, binary: String) -> AgentDefinition {
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
