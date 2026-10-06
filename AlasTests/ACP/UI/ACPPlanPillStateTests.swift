import Foundation
import Testing
@testable import Alas

@Suite("ACPPlanPillState")
struct ACPPlanPillStateTests {
    private typealias Item = ACPMessage.PlanItem

    @Test("missing and empty plans have no task control", arguments: [nil, []] as [[Item]?])
    func nilForMissingOrEmpty(items: [ACPMessage.PlanItem]?) {
        #expect(ACPPlanPillState(items: items) == nil)
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

    @Test("unfinished task animation follows turn activity", arguments: [true, false])
    func inProgressDrivesEverything(isTurnActive: Bool) {
        let items: [Item] = [
            .init(content: "Read code",    status: "completed"),
            .init(content: "Sketch design",status: "completed"),
            .init(content: "Implement",    status: "in_progress"),
            .init(content: "Test",         status: "pending")
        ]
        let state = ACPPlanPillState(items: items, isTurnActive: isTurnActive)
        #expect(state?.done == 2)
        #expect(state?.total == 4)
        #expect(state?.currentStep == "Implement")
        #expect(state?.isAnimating == isTurnActive)
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

    @Test("active task progress uses its one-based position", arguments: [
        (0, "1/5", "Tasks, 0 of 5 complete, Phase 1"),
        (4, "5/5", "Tasks, 4 of 5 complete, Phase 5"),
    ])
    func displayStrings(activeIndex: Int, expectedProgress: String, expectedAccessibilityLabel: String) {
        let items = (0..<5).map { index in
            let status = index < activeIndex ? "completed" : index == activeIndex ? "in_progress" : "pending"
            return Item(content: "Phase \(index + 1)", status: status)
        }
        let state = ACPPlanPillState(items: items)

        #expect(state?.progressText == expectedProgress)
        #expect(state?.accessibilityLabel == expectedAccessibilityLabel)
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
