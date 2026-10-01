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

    @Test("summary includes objective, normalized status, and rounded token budget")
    func summaryWithStatusAndBudget() {
        let goal = ACPGoalState(
            objective: "Surface richer events",
            status: "in_progress",
            tokenBudget: 12_000
        )

        #expect(ACPGoalPill.summary(goal) == "Goal: Surface richer events · in progress · 12k")
    }

    @Test("summary truncates long objectives")
    func summaryTruncatesLongObjective() {
        let objective = String(repeating: "a", count: 61)
        let goal = ACPGoalState(objective: objective, status: "in_progress", tokenBudget: nil)

        #expect(ACPGoalPill.summary(goal) == "Goal: \(String(repeating: "a", count: 60))… · in progress")
    }

    @Test("summary omits nil status")
    func summaryOmitsNilStatus() {
        let goal = ACPGoalState(objective: "Ship transcript UI", status: nil, tokenBudget: 8_000)

        #expect(ACPGoalPill.summary(goal) == "Goal: Ship transcript UI · 8k")
    }

    @Test("summary keeps one decimal for non-round token budgets")
    func summaryFormatsNonRoundTokenBudget() {
        let goal = ACPGoalState(objective: "Ship transcript UI", status: "done", tokenBudget: 12_500)

        #expect(ACPGoalPill.summary(goal) == "Goal: Ship transcript UI · done · 12.5k")
    }

    @Test("summary keeps sub-thousand token budgets numeric")
    func summaryFormatsSmallTokenBudget() {
        let goal = ACPGoalState(objective: "Ship transcript UI", status: "done", tokenBudget: 999)

        #expect(ACPGoalPill.summary(goal) == "Goal: Ship transcript UI · done · 999")
    }
}
