import Foundation
import Testing
@testable import Alas

@Suite("ACP side question policy")
struct ACPSideQuestionPolicyTests {
    static let claudeModes: [ACPModeInfo] = [
        .init(id: "default", name: "Manual", kind: .standard),
        .init(id: "plan", name: "Plan", kind: .plan),
        .init(id: "bypassPermissions", name: "Bypass", kind: .fullAccess),
    ]
    static let codexModes: [ACPModeInfo] = [
        .init(id: "read-only", name: "Ask for approval", kind: .standard),
        .init(id: "agent", name: "Approve for me", kind: .autoReview),
        .init(id: "agent-full-access", name: "Full access", kind: .fullAccess),
    ]

    @Test(
        "side sessions switch to plan, or away from self-approving modes",
        arguments: [
            (claudeModes, "bypassPermissions", Optional("plan")),
            (claudeModes, "plan", nil),
            (codexModes, "agent-full-access", "read-only"),
            (codexModes, "agent", "read-only"),
            (codexModes, "read-only", nil),
            ([], nil, nil),
        ] as [([ACPModeInfo], String?, String?)]
    )
    func preferredMode(modes: [ACPModeInfo], current: String?, expected: String?) {
        #expect(ACPSideQuestionModePolicy.preferredModeID(modes: modes, currentModeID: current) == expected)
    }
}
