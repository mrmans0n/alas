import Testing
@testable import Alas

@MainActor
@Suite("ACP session fork presentation")
struct ACPSessionForkPresentationTests {
    @Test("current target is first and remaining targets preserve ACP catalog order")
    func targetOrdering() {
        let targets = ACPForkTargetPolicy.targets(
            sourceAgentID: "codex",
            enabledAgents: [
                .init(id: "claude", displayName: "Claude"),
                .init(id: "gemini", displayName: "Gemini"),
            ],
            sourceAgent: .init(id: "codex", displayName: "Codex"),
            catalogAgentIDs: ["claude", "gemini", "codex"]
        )
        #expect(targets.map(\.id) == ["codex", "claude", "gemini"])
        #expect(targets.first?.isSameAgent == true)
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
