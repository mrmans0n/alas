import Foundation
import Testing
@testable import Alas

@Suite("ACP side question policy")
struct ACPSideQuestionPolicyTests {
    static let claudeModes: [ChipSpec.Item] = [
        .init(id: "default", name: "Manual", description: nil, kind: .standard),
        .init(id: "plan", name: "Plan", description: nil, kind: .plan),
        .init(id: "bypassPermissions", name: "Bypass", description: nil, kind: .fullAccess),
    ]
    static let codexModes: [ChipSpec.Item] = [
        .init(id: "read-only", name: "Ask for approval", description: nil, kind: .standard),
        .init(id: "agent", name: "Approve for me", description: nil, kind: .autoReview),
        .init(id: "agent-full-access", name: "Full access", description: nil, kind: .fullAccess),
    ]
    static let fullAccessOnly: [ChipSpec.Item] = [
        .init(id: "yolo", name: "YOLO", description: nil, kind: .fullAccess),
    ]
    /// An adapter that predates `_meta.kind`.
    static let unclassifiedClaude: [ChipSpec.Item] = [
        .init(id: "default", name: "Manual", description: nil),
        .init(id: "bypassPermissions", name: "Bypass", description: nil),
    ]
    static let unknownModes: [ChipSpec.Item] = [
        .init(id: "turbo", name: "Turbo", description: nil),
    ]

    @Test(
        "side sessions switch to plan, or away from self-approving modes",
        arguments: [
            (claudeModes, "bypassPermissions", Optional("plan"), false),
            (claudeModes, "plan", nil, true),
            (codexModes, "agent-full-access", "read-only", false),
            (codexModes, "agent", "read-only", false),
            (codexModes, "read-only", nil, true),
            (fullAccessOnly, "yolo", nil, false),
            (unclassifiedClaude, "bypassPermissions", "default", false),
            (unclassifiedClaude, "default", nil, true),
            (unknownModes, "turbo", nil, false),
            ([], nil, nil, true),
        ] as [([ChipSpec.Item], String?, String?, Bool)]
    )
    func preferredMode(options: [ChipSpec.Item], current: String?, expected: String?, currentAllowed: Bool) {
        #expect(ACPSideQuestionModePolicy.preferredModeID(options: options, currentID: current) == expected)
        #expect(ACPSideQuestionModePolicy.allows(options: options, currentID: current) == currentAllowed)
    }
}
