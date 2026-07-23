import Foundation
import Testing
@testable import Alas

@Suite("ACPPlanPillState")
struct ACPPlanPillStateTests {
    private typealias Item = ACPMessage.PlanItem

    @Test("nil for missing items")
    func nilForMissing() {
        #expect(ACPPlanPillState(items: nil) == nil)
    }

    @Test("nil for empty items array")
    func nilForEmpty() {
        #expect(ACPPlanPillState(items: []) == nil)
    }

    @Test("closing for a missing plan stays closed when the next plan arrives")
    func popoverDoesNotReopenAfterPlanReturns() {
        let items: [Item] = [.init(content: "Implement", status: "in_progress")]
        let closedForMissingPlan = ACPPlanPillState.popoverOpenAfterPlanChange(
            wasOpen: true,
            items: nil
        )

        #expect(closedForMissingPlan == false)
        #expect(ACPPlanPillState.popoverOpenAfterPlanChange(
            wasOpen: closedForMissingPlan,
            items: items
        ) == false)
    }

    @Test("in_progress step drives current step and turns animation on")
    func inProgressDrivesEverything() {
        let items: [Item] = [
            .init(content: "Read code",    status: "completed"),
            .init(content: "Sketch design",status: "completed"),
            .init(content: "Implement",    status: "in_progress"),
            .init(content: "Test",         status: "pending")
        ]
        let state = ACPPlanPillState(items: items)
        #expect(state?.done == 2)
        #expect(state?.total == 4)
        #expect(state?.currentStep == "Implement")
        #expect(state?.isAnimating == true)
    }

    @Test("all pending — first pending becomes current, animation off")
    func allPending() {
        let items: [Item] = [
            .init(content: "Read",     status: "pending"),
            .init(content: "Implement",status: "pending")
        ]
        let state = ACPPlanPillState(items: items)
        #expect(state?.done == 0)
        #expect(state?.total == 2)
        #expect(state?.currentStep == "Read")
        #expect(state?.isAnimating == false)
    }

    @Test("all completed — currentStep reads as completion message")
    func allCompleted() {
        let items: [Item] = [
            .init(content: "Read",     status: "completed"),
            .init(content: "Implement",status: "completed")
        ]
        let state = ACPPlanPillState(items: items)
        #expect(state?.done == 2)
        #expect(state?.total == 2)
        #expect(state?.currentStep == "All steps complete")
        #expect(state?.isAnimating == false)
    }

    @Test("mixed without in_progress — first pending wins")
    func mixedDoneAndPending() {
        let items: [Item] = [
            .init(content: "Read",     status: "completed"),
            .init(content: "Sketch",   status: "pending"),
            .init(content: "Implement",status: "pending")
        ]
        let state = ACPPlanPillState(items: items)
        #expect(state?.done == 1)
        #expect(state?.total == 3)
        #expect(state?.currentStep == "Sketch")
        #expect(state?.isAnimating == false)
    }

    @Test("display strings keep compact and accessibility copy distinct")
    func displayStrings() {
        let state = ACPPlanPillState(items: [
            .init(content: "Read code", status: "completed"),
            .init(content: "Implement toolbar control", status: "in_progress"),
            .init(content: "Test", status: "pending")
        ])

        #expect(state?.progressText == "1/3")
        #expect(state?.accessibilityLabel
            == "Tasks, 1 of 3 complete, Implement toolbar control")
    }

    @Test("outline animation respects activity and Reduce Motion")
    func outlineAnimationPolicy() {
        let active = ACPPlanPillState(items: [
            .init(content: "Implement", status: "in_progress")
        ])
        let pending = ACPPlanPillState(items: [
            .init(content: "Implement", status: "pending")
        ])

        #expect(active?.outlineIsAnimated(reduceMotion: false) == true)
        #expect(active?.outlineIsAnimated(reduceMotion: true) == false)
        #expect(pending?.outlineIsAnimated(reduceMotion: false) == false)
    }

    @Test("unknown status keeps fallback title without animation")
    func unknownStatusFallback() {
        let state = ACPPlanPillState(items: [
            .init(content: "Agent-defined state", status: "blocked")
        ])

        #expect(state?.currentStep == "Agent-defined state")
        #expect(state?.isAnimating == false)
    }
}
