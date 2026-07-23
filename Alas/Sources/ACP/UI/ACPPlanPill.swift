import SwiftUI

/// Compact task control in the ACP toolbar. It surfaces the current plan
/// and opens the full checklist in a popover.
///
/// Observes `ACPTranscript` directly rather than `ACPSession` so the pill
/// re-renders when only the plan changes (`apply(.plan)` mutates
/// `transcript.messages` only; `ACPSession` does not forward
/// `transcript.objectWillChange`).
struct ACPPlanPill: View {
    @ObservedObject var transcript: ACPTranscript
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popoverOpen = false

    var body: some View {
        Group {
            if let state = ACPPlanPillState(items: transcript.currentPlan) {
                pill(state: state)
            }
        }
        .onChange(of: transcript.currentPlan) { _, items in
            popoverOpen = ACPPlanPillState.popoverOpenAfterPlanChange(
                wasOpen: popoverOpen,
                items: items
            )
        }
    }

    @ViewBuilder
    private func pill(state: ACPPlanPillState) -> some View {
        Button {
            popoverOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Text("Tasks")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(state.progressText)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                Text("·")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
                Text(state.currentStep)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .foregroundStyle(theme.color("accent"))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.color("accent").opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                taskOutline(state: state)
            }
        }
        .buttonStyle(.plain)
        .help(state.accessibilityLabel)
        .accessibilityLabel(state.accessibilityLabel)
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            if let items = transcript.currentPlan, !items.isEmpty {
                ACPPlanChecklist(items: items)
                    .frame(width: 320)
            }
        }
    }

    @ViewBuilder
    private func taskOutline(state: ACPPlanPillState) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        shape
            .strokeBorder(
                theme.color("accent").opacity(state.isAnimating ? 0.48 : 0.28),
                lineWidth: state.isAnimating ? 0.75 : 0.5
            )

        if state.outlineIsAnimated(reduceMotion: reduceMotion) {
            TimelineView(.animation) { context in
                let cycleSeconds = 1.8
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycleSeconds) / cycleSeconds
                shape
                    .strokeBorder(travelingGradient(phase: phase), lineWidth: 1.25)
            }
        }
    }

    private func travelingGradient(phase: Double) -> AngularGradient {
        let start = Angle.degrees(phase * 360)
        return AngularGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.72),
                .init(color: theme.color("accent").opacity(0.20), location: 0.80),
                .init(color: theme.color("accent").opacity(0.65), location: 0.90),
                .init(color: theme.color("accent"), location: 0.97),
                .init(color: .clear, location: 1.00)
            ],
            center: .center,
            startAngle: start,
            endAngle: start + .degrees(360)
        )
    }
}
