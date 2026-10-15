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
        "Alas commands are parsed only as their own command",
        arguments: [
            ("/btw why SQLite?", Optional(ACPAlasSlashCommand.btw(question: "why SQLite?"))),
            ("  /btw   why?  ", .btw(question: "why?")),
            ("/btw\nwhy\nnot?", .btw(question: "why\nnot?")),
            ("/btw", .btw(question: "")),
            ("/btwx", nil),
            ("/BTW why?", nil),
            ("please /btw", nil),
            (" /ship ", .ship(arguments: "")),
            ("/ship now", .ship(arguments: "now")),
            ("/shipit", nil),
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
        "/btw opens a side question only when it can run as drafted",
        arguments: [
            ("/btw why?", false, ACPSubmitIntent.auto, true, ACPSideQuestionSubmitRoute.ask(question: "why?")),
            ("/btw why?", false, .steer, true, .ask(question: "why?")),
            ("/btw why?", false, .auto, false, .passThrough),
            ("why?", false, .auto, true, .passThrough),
            ("/btw why?", true, .auto, true,
             .refuse("/btw doesn't support attachments yet. Remove them to ask a side question.")),
            ("/btw why?", false, .schedule(.distantFuture), true,
             .refuse("/btw can't be scheduled. Send it now to ask a side question.")),
        ] as [(String, Bool, ACPSubmitIntent, Bool, ACPSideQuestionSubmitRoute)]
    )
    func submitRoute(
        text: String, hasAttachments: Bool, intent: ACPSubmitIntent, isAvailable: Bool,
        expected: ACPSideQuestionSubmitRoute
    ) {
        #expect(ACPSideQuestionSubmitRoute.resolve(
            text: text, hasAttachments: hasAttachments, intent: intent, isAvailable: isAvailable
        ) == expected)
    }

    @Test(
        "card phase follows creation, session errors, and the turn's output",
        arguments: [
            ("", nil, false, nil, false, false, false, ACPSideQuestionPhase.composing),
            ("q", nil, false, nil, false, false, false, .starting),
            ("q", "fork failed", false, nil, false, false, false, .failed("fork failed")),
            ("q", nil, true, "adapter crashed", true, true, true, .failed("adapter crashed")),
            ("q", nil, true, nil, false, false, false, .starting),
            ("q", nil, true, nil, true, true, false, .starting),
            ("q", nil, true, nil, true, true, true, .streaming),
            ("q", nil, true, nil, false, true, true, .answered),
            ("q", nil, true, nil, false, true, false, .answered),
        ] as [(String, String?, Bool, String?, Bool, Bool, Bool, ACPSideQuestionPhase)]
    )
    func phase(
        question: String, creationError: String?, hasSession: Bool,
        sessionError: String?, isTurnActive: Bool, hasPrompt: Bool, hasOutput: Bool,
        expected: ACPSideQuestionPhase
    ) {
        #expect(ACPSideQuestionPhase.resolve(
            question: question, creationError: creationError, hasSession: hasSession,
            sessionError: sessionError, isTurnActive: isTurnActive,
            hasPrompt: hasPrompt, hasOutput: hasOutput
        ) == expected)
    }

    @Test(
        "read-only is enforced only on agents whose read-only mode holds",
        arguments: [("claude", true), ("codex", true), ("opencode", false), ("pi", false), ("copilot", false), ("my-agent", false)]
    )
    func readOnlyEnforcement(agentId: String, enforced: Bool) {
        #expect(ACPSideQuestionSupportPolicy.enforcesReadOnly(agentId: agentId) == enforced)
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

    // MARK: Dock layout

    static let dockSurface = CGSize(width: 1000, height: 800)

    @Test(
        "a dragged header drops onto the zone under the pointer, or nowhere",
        arguments: [
            (CGPoint(x: 500, y: 100), Optional(ACPSideQuestionDock.top)),
            (CGPoint(x: 900, y: 100), .top),
            (CGPoint(x: 900, y: 400), .side),
            (CGPoint(x: 900, y: 750), .side),
            (CGPoint(x: 300, y: 750), .composer),
            (CGPoint(x: 300, y: 400), nil),
            (CGPoint(x: -5, y: 100), nil),
            (CGPoint(x: 500, y: 900), nil),
        ] as [(CGPoint, ACPSideQuestionDock?)]
    )
    func dockDropZone(point: CGPoint, expected: ACPSideQuestionDock?) {
        #expect(ACPSideQuestionDockLayout.dock(at: point, in: Self.dockSurface) == expected)
    }

    @Test(
        "card height stays between 120pt and 70% of the surface, the minimum winning on tiny surfaces",
        arguments: [
            (CGFloat(50), CGFloat(800), CGFloat(120)),
            (300, 800, 300),
            (700, 800, 560),
            (300, 100, 120),
        ] as [(CGFloat, CGFloat, CGFloat)]
    )
    func dockHeightClamp(height: CGFloat, surfaceHeight: CGFloat, expected: CGFloat) {
        #expect(ACPSideQuestionDockLayout.clampedHeight(height, surfaceHeight: surfaceHeight) == expected)
    }

    @Test(
        "side width stays between 300pt and half the surface, the minimum winning on narrow surfaces",
        arguments: [
            (CGFloat(100), CGFloat(1000), CGFloat(300)),
            (400, 1000, 400),
            (900, 1000, 500),
            (400, 400, 300),
        ] as [(CGFloat, CGFloat, CGFloat)]
    )
    func dockSideWidthClamp(width: CGFloat, surfaceWidth: CGFloat, expected: CGFloat) {
        #expect(ACPSideQuestionDockLayout.clampedSideWidth(width, surfaceWidth: surfaceWidth) == expected)
    }

    @Test(
        "a pending prompt grows the card up to the limit, then shrinks the answer, then scrolls",
        arguments: [
            // cap, limit, chrome, promptIdeal -> answer, prompt
            (CGFloat(260), CGFloat(560), CGFloat(80), CGFloat(0), CGFloat(180), CGFloat(0)),
            (260, 560, 80, 200, 180, 200),
            (260, 560, 80, 350, 130, 350),
            (260, 560, 80, 450, 60, 420),
            (100, 560, 80, 0, 60, 0),
        ] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)]
    )
    func dockBodyHeights(
        cap: CGFloat, limit: CGFloat, chrome: CGFloat, promptIdeal: CGFloat,
        answer: CGFloat, prompt: CGFloat
    ) {
        let heights = ACPSideQuestionDockLayout.bodyHeights(
            cap: cap, limit: limit, chrome: chrome, promptIdeal: promptIdeal
        )
        #expect(heights == .init(answer: answer, prompt: prompt))
    }

    @Test(
        "dock preferences keep what decodes and default the rest",
        arguments: [
            (#"{"dock":"side"}"#, ACPSideQuestionDock.side, 260.0, 380.0),
            (#"{"dock":"floating","sideWidth":420}"#, .composer, 260.0, 420.0),
            (#"{}"#, .composer, 260.0, 380.0),
        ] as [(String, ACPSideQuestionDock, Double, Double)]
    )
    func dockPreferencesDecode(json: String, dock: ACPSideQuestionDock, composerHeight: Double, sideWidth: Double) throws {
        let prefs = try JSONDecoder().decode(ACPSideQuestionDockPreferences.self, from: Data(json.utf8))
        #expect(prefs.dock == dock)
        #expect(prefs.composerHeight == composerHeight)
        #expect(prefs.sideWidth == sideWidth)
    }

    @Test("blocked calls collapse to one entry per title, in first-seen order")
    func blockedSummary() {
        let summary = ACPSideQuestionBlockedSummary([
            .init(title: "write a.swift", messageIndex: 3),
            .init(title: "run make", messageIndex: 4),
            .init(title: "write a.swift", messageIndex: 5),
        ])
        #expect(summary.entries == [.init(title: "write a.swift", count: 2), .init(title: "run make", count: 1)])
        #expect(summary.label == "3 actions skipped · read-only")
        #expect(ACPSideQuestionBlockedSummary([.init(title: "run make", messageIndex: 1)]).label
            == "1 action skipped · read-only")
    }
}
