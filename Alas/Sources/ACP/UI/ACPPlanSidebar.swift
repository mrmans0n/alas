import SwiftUI

/// Inline right-side plan surface. Shown by `ACPSessionView` when the
/// pane is wide enough (see `ACPPlanSidebarVisibility`). Mirrors the
/// pill's popover content via the shared `ACPPlanChecklist`, hosted in
/// a 320pt column as a floaty rounded card with the same animated
/// laser border the toolbar pill uses while a step is in progress.
///
/// Observes `ACPTranscript` directly so plan updates re-render here
/// (same reason `ACPPlanPill` observes it directly — `ACPSession`
/// doesn't forward transcript changes).
///
/// Spec: `docs/superpowers/specs/2026-05-29-acp-plan-sidebar-design.md` (§3)
struct ACPPlanSidebar: View {
    @ObservedObject var transcript: ACPTranscript
    let onMinimize: () -> Void
    @Environment(\.theme) private var theme

    private let cornerRadius: CGFloat = 12

    var body: some View {
        let items = transcript.latestPlan ?? []
        let animating = items.contains { $0.status == "in_progress" }
        ScrollView(.vertical, showsIndicators: false) {
            if !items.isEmpty {
                ACPPlanChecklist(items: items, onMinimize: onMinimize)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(laserBorder(animating: animating))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
                    .padding(12)
            } else {
                // The caller gates rendering on hasPlan, so we
                // shouldn't be visible without a plan; render an
                // empty placeholder rather than crashing if items
                // race to nil before the visibility flips.
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel(for: items))
    }

    @ViewBuilder
    private func laserBorder(animating: Bool) -> some View {
        if animating {
            TimelineView(.animation) { context in
                let cycleSeconds: Double = 2.2
                let now = context.date.timeIntervalSinceReferenceDate
                let phase = (now.truncatingRemainder(dividingBy: cycleSeconds)) / cycleSeconds
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(snakeGradient(phase: phase), lineWidth: 1.25)
            }
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(theme.color("accent").opacity(0.35), lineWidth: 1)
        }
    }

    private func snakeGradient(phase: Double) -> AngularGradient {
        let accent = theme.color("accent")
        let start = Angle.degrees(phase * 360.0)
        return AngularGradient(
            stops: [
                .init(color: .clear,              location: 0.00),
                .init(color: .clear,              location: 0.60),
                .init(color: accent.opacity(0.4), location: 0.75),
                .init(color: accent,              location: 0.88),
                .init(color: accent.opacity(0.4), location: 0.96),
                .init(color: .clear,              location: 1.00)
            ],
            center: .center,
            startAngle: start,
            endAngle: start + .degrees(360)
        )
    }

    private func accessibilityLabel(for items: [ACPMessage.PlanItem]) -> String {
        guard let state = ACPPlanPillState(items: items) else { return "Plan" }
        return "Plan, \(state.done) of \(state.total) complete — \(state.currentStep)"
    }
}
