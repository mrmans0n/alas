import Foundation
import Testing
@testable import Alas

@Suite("ACPGoalPill")
struct ACPGoalPillTests {
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
