import Foundation

/// Pure derivation: collapses a `[PlanItem]` into the four values the
/// toolbar pill needs. Lives outside `ACPPlanPill` so it can be tested
/// without spinning up SwiftUI.
struct ACPPlanPillState: Equatable {
    let done: Int
    let total: Int
    let currentStep: String
    let isAnimating: Bool

    /// Returns nil for a missing or empty plan — the view layer treats
    /// nil as "render no pill at all".
    init?(items: [ACPMessage.PlanItem]?) {
        guard let items, !items.isEmpty else { return nil }
        self.total = items.count
        self.done = items.filter { $0.status == "completed" }.count

        if let inProgress = items.first(where: { $0.status == "in_progress" }) {
            self.currentStep = inProgress.content
            self.isAnimating = true
        } else if done == total {
            self.currentStep = "All steps complete"
            self.isAnimating = false
        } else if let pending = items.first(where: { $0.status == "pending" }) {
            self.currentStep = pending.content
            self.isAnimating = false
        } else {
            // Unknown status values fall through — show the last item's
            // content as a least-bad default. Snake stays off.
            self.currentStep = items.last?.content ?? ""
            self.isAnimating = false
        }
    }

    /// An open popover needs an existing pill to anchor to. Once the plan
    /// disappears, retain the closed state if a later plan arrives.
    static func popoverOpenAfterPlanChange(
        wasOpen: Bool,
        items: [ACPMessage.PlanItem]?
    ) -> Bool {
        wasOpen && ACPPlanPillState(items: items) != nil
    }

    var progressText: String {
        "\(done)/\(total)"
    }

    var accessibilityLabel: String {
        "Tasks, \(done) of \(total) complete, \(currentStep)"
    }

    func outlineIsAnimated(reduceMotion: Bool) -> Bool {
        isAnimating && !reduceMotion
    }
}
