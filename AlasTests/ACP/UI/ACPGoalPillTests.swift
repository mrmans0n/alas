import Foundation
import Testing
@testable import Alas

@Suite("ACPGoalPill")
struct ACPGoalPillTests {
    @Test(
        "actions follow goal status and advertised capability",
        arguments: [
            (Optional<String>.none, [ACPGoalAction.set]),
            (Optional("active"), [.set, .pause, .clear]),
            (Optional("in_progress"), [.set, .pause, .clear]),
            (Optional("paused"), [.set, .resume, .clear]),
            (Optional("complete"), [.set, .clear]),
            (Optional("completed"), [.set, .clear]),
            (Optional("blocked"), [.set, .clear]),
            (Optional("limited"), [.set, .clear]),
            (Optional("future"), [.set, .clear]),
        ]
    )
    func actionsFollowStatus(status: String?, expected: [ACPGoalAction]) {
        let goal = status.map { ACPGoalState(objective: "Ship it", status: $0, tokenBudget: nil) }
        let capability = ACPGoalCapability(
            version: 1,
            controlMethod: "_session/goal",
            actions: Set(ACPGoalAction.allCases)
        )

        #expect(ACPGoalPill.actions(for: goal, capability: capability) == expected)
    }

    @Test("actions never include unadvertised controls")
    func actionsRequireAdvertisement() {
        let capability = ACPGoalCapability(
            version: 1,
            controlMethod: "_session/goal",
            actions: [.set, .clear]
        )
        let goal = ACPGoalState(objective: "Ship it", status: "paused", tokenBudget: nil)

        #expect(ACPGoalPill.actions(for: goal, capability: capability) == [.set, .clear])
    }

    @Test("duration formatting handles values larger than Int")
    func durationFormattingHandlesOversizedValues() {
        #expect(ACPGoalControl.formattedDuration(1e20) == "100000000000000000000s")
    }

    @Test(
        "summary carries the full objective, normalized status, and token usage",
        arguments: [
            (Optional("in_progress"), Optional(12_000), Optional<Int>.none,
             "Goal: Ship transcript UI · in progress · 12k budget"),
            (nil, 8_000, 2_400, "Goal: Ship transcript UI · 2.4k / 8k"),
            ("done", nil, 999, "Goal: Ship transcript UI · done · 999 used"),
            ("done", 12_500, nil, "Goal: Ship transcript UI · done · 12.5k budget"),
            ("", nil, nil, "Goal: Ship transcript UI"),
        ]
    )
    func summaryFormatsStatusAndTokens(status: String?, budget: Int?, used: Int?, expected: String) {
        let goal = ACPGoalState(objective: "Ship transcript UI", status: status, tokenBudget: budget, tokensUsed: used)

        #expect(ACPGoalPill.summary(goal) == expected)
    }

    @Test("pill title truncates long objectives while the summary keeps them whole")
    func pillTitleTruncatesLongObjective() {
        let objective = String(repeating: "a", count: 41)
        let goal = ACPGoalState(objective: objective, status: nil, tokenBudget: nil)

        #expect(ACPGoalPill.pillTitle(goal) == "\(String(repeating: "a", count: 40))…")
        #expect(ACPGoalPill.summary(goal) == "Goal: \(objective)")
    }

    @Test(
        "only running goals animate, and never under Reduce Motion",
        arguments: [
            ("active", false, true),
            ("in_progress", false, true),
            ("in_progress", true, false),
            ("paused", false, false),
            ("complete", false, false),
        ]
    )
    func sheenFollowsPhaseAndReduceMotion(status: String, reduceMotion: Bool, expected: Bool) {
        let goal = ACPGoalState(objective: "Ship it", status: status, tokenBudget: nil)

        #expect(ACPGoalPill.showsSheen(for: goal, reduceMotion: reduceMotion) == expected)
    }

    @Test(
        "token progress needs both used and a positive budget, clamped to full",
        arguments: [
            (Optional(2_500), Optional(10_000), Optional(0.25)),
            (12_000, 10_000, 1.0),
            (2_500, nil, nil),
            (nil, 10_000, nil),
            (0, 0, nil),
        ]
    )
    func tokenProgress(used: Int?, budget: Int?, expected: Double?) {
        let goal = ACPGoalState(objective: "Ship it", status: "active", tokenBudget: budget, tokensUsed: used)

        #expect(ACPGoalPill.tokenProgress(goal) == expected)
    }
}
