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
        "card phase follows creation, session errors, and the answer",
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
        sessionError: String?, isTurnActive: Bool, hasAnswer: Bool,
        expected: ACPSideQuestionPhase
    ) {
        #expect(ACPSideQuestionPhase.resolve(
            question: question, creationError: creationError, hasSession: hasSession,
            sessionError: sessionError, isTurnActive: isTurnActive, hasAnswer: hasAnswer
        ) == expected)
    }
}
