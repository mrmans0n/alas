import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork presentation")
struct ACPSessionForkPresentationTests {
    @Test("native and transcript forks use honest divider copy")
    func dividerCopy() {
        #expect(ACPSessionForkPresentation(
            sourceAgentName: "Claude", mechanism: .nativeACP
        ).title == "Forked from Claude")
        let imported = ACPSessionForkPresentation(
            sourceAgentName: "Claude", mechanism: .transcriptTransfer
        )
        #expect(imported.title == "Conversation imported from Claude")
        #expect(imported.notice ==
            "Provider-specific tool state, hidden context, and attachments were not transferred. This chat shares the source chat’s current worktree.")
    }

    @Test("current target is first and remaining targets preserve ACP catalog order")
    func targetOrdering() {
        let targets = ACPForkTargetPolicy.targets(
            sourceAgentID: "codex",
            enabledAgents: [
                .init(id: "claude", displayName: "Claude", logoAssetName: "agent-claude"),
                .init(id: "gemini", displayName: "Gemini", logoAssetName: "agent-gemini"),
                .init(id: "codex", displayName: "Codex", logoAssetName: "agent-codex")
            ],
            catalogAgentIDs: ["claude", "gemini", "codex"]
        )
        #expect(targets.map(\.id) == ["codex", "claude", "gemini"])
        #expect(targets.first?.isSameAgent == true)
        #expect(targets.first?.logoAssetName == "agent-codex")
    }

    @Test("message menu only offers fork for eligible rows")
    func menuEligibility() {
        #expect(ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "user", isEligible: true, targetCount: 2
        ))
        #expect(!ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "agent", isEligible: false, targetCount: 2
        ))
        #expect(!ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: "tool_call", isEligible: true, targetCount: 2
        ))
    }
}
