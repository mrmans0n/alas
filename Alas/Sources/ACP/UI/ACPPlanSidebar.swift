import SwiftUI

/// Inline right-side plan surface. Shown by `ACPSessionView` when the
/// pane is wide enough (see `ACPPlanSidebarVisibility`). Mirrors the
/// pill's popover content via the shared `ACPPlanChecklist`, just
/// hosted in a fixed 320pt column with a left divider and an outer
/// scroll view.
///
/// Observes `ACPTranscript` directly so plan updates re-render here
/// (same reason `ACPPlanPill` observes it directly — `ACPSession`
/// doesn't forward transcript changes).
///
/// Spec: `docs/superpowers/specs/2026-05-29-acp-plan-sidebar-design.md` (§3)
struct ACPPlanSidebar: View {
    @ObservedObject var transcript: ACPTranscript
    @Environment(\.theme) private var theme

    var body: some View {
        let items = transcript.latestPlan ?? []
        HStack(spacing: 0) {
            Rectangle()
                .fill(theme.color("line"))
                .frame(width: 0.5)
            ScrollView(.vertical, showsIndicators: false) {
                if !items.isEmpty {
                    ACPPlanChecklist(items: items)
                } else {
                    // The caller gates rendering on hasPlan, so we
                    // shouldn't be visible without a plan; render an
                    // empty placeholder rather than crashing if items
                    // race to nil before the visibility flips.
                    Color.clear.frame(height: 1)
                }
            }
            .frame(maxHeight: .infinity)
            .background(theme.color("bg-1"))
        }
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(for: items))
    }

    private func accessibilityLabel(for items: [ACPMessage.PlanItem]) -> String {
        guard let state = ACPPlanPillState(items: items) else { return "Plan" }
        return "Plan, \(state.done) of \(state.total) complete — \(state.currentStep)"
    }
}
