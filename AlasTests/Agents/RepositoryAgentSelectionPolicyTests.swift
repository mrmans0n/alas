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

    @Test func automaticPicksFirstEligibleAgentAndOffPicksNone() {
        let pi = agent(id: "pi", binary: "pi")
        var claude = agent(id: "claude", binary: "claude")
        claude.bypassPermissionsFlag = "--dangerously-skip-permissions"
        let availability = AgentAvailabilityState.available([pi, claude])

        #expect(RepositoryAgentSelectionPolicy.selection(
            selectedID: AppConfig.Changes.automaticAIToolID,
            availability: availability
        ).agent?.id == "pi")
        #expect(RepositoryAgentSelectionPolicy.selection(
            selectedID: AppConfig.Changes.automaticAIToolID,
            availability: availability,
            where: { $0.bypassPermissionsFlag != nil }
        ).agent?.id == "claude")
        #expect(RepositoryAgentSelectionPolicy.selection(
            selectedID: AppConfig.Changes.disabledAIToolID,
            availability: availability
        ) == .selectionUnavailable)
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
