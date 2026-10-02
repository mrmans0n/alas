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

    @Test(
        "/btw is parsed only as its own command",
        arguments: [
            ("/btw why SQLite?", Optional(ACPAlasSlashCommand.btw(question: "why SQLite?"))),
            ("  /btw   why?  ", .btw(question: "why?")),
            ("/btw\nwhy\nnot?", .btw(question: "why\nnot?")),
            ("/btw", .btw(question: "")),
            ("/btwx", nil),
            ("/BTW why?", nil),
            ("please /btw", nil),
        ] as [(String, ACPAlasSlashCommand?)]
    )
    func parse(text: String, expected: ACPAlasSlashCommand?) {
        #expect(ACPAlasSlashCommand.parse(text) == expected)
    }

    @Test("Alas commands come first and hide an agent command of the same name")
    func suggestionMerge() {
        let agentBtw = ACPPromptSuggestion(command: "/btw", description: "Agent side question")
        let review = ACPPromptSuggestion(command: "/review", description: "Review")
        let btw = ACPAlasSlashCommand.btwSuggestion

        #expect(ACPAlasSlashCommand.suggestions(alas: [btw], agent: [review, agentBtw]) == [btw, review])
        #expect(ACPAlasSlashCommand.suggestions(alas: [btw], agent: []) == [btw])
        #expect(ACPAlasSlashCommand.suggestions(alas: [], agent: [agentBtw]) == [agentBtw])
    }

    @Test(
        "card phase follows creation, session errors, and the turn's output",
        arguments: [
            ("", nil, false, nil, false, false, ACPSideQuestionPhase.composing),
            ("q", nil, false, nil, false, false, .starting),
            ("q", "fork failed", false, nil, false, false, .failed("fork failed")),
            ("q", nil, true, "adapter crashed", true, true, .failed("adapter crashed")),
            ("q", nil, true, nil, true, false, .starting),
            ("q", nil, true, nil, true, true, .streaming),
            ("q", nil, true, nil, false, true, .answered),
        ] as [(String, String?, Bool, String?, Bool, Bool, ACPSideQuestionPhase)]
    )
    func phase(
        question: String, creationError: String?, hasSession: Bool,
        sessionError: String?, isTurnActive: Bool, hasOutput: Bool,
        expected: ACPSideQuestionPhase
    ) {
        #expect(ACPSideQuestionPhase.resolve(
            question: question, creationError: creationError, hasSession: hasSession,
            sessionError: sessionError, isTurnActive: isTurnActive, hasOutput: hasOutput
        ) == expected)
    }

    @Test(
        "side questions only run on agents that ask before each tool call",
        arguments: [("claude", true), ("codex", true), ("opencode", true), ("pi", false), ("copilot", false)]
    )
    func readOnlySupport(agentId: String, supported: Bool) {
        #expect(ACPSideQuestionSupportPolicy.canEnforceReadOnly(agentId: agentId) == supported)
    }

    @Test(
        "a config-backed mode change counts only when the echo selects the target",
        arguments: [
            ([] as [ACPConfigOption], true),
            ([modeOption(current: "plan")], true),
            ([modeOption(current: "bypassPermissions")], false),
            ([ACPConfigOption(id: "effort", name: "Effort", type: "select", category: nil,
                              currentValue: .string("high"), options: [])], false),
        ]
    )
    func modeEcho(echoed: [ACPConfigOption], accepted: Bool) {
        #expect(ACPSideQuestionModePolicy.acceptsEcho(echoed, configID: "mode", target: "plan") == accepted)
    }

    static func modeOption(current: String) -> ACPConfigOption {
        ACPConfigOption(id: "mode", name: "Mode", type: "select", category: "mode",
                        currentValue: .string(current), options: [])
    }
}
