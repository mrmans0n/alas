import SwiftUI

/// Floaty pill that lives in the ACP toolbar and surfaces the latest
/// plan from the session's transcript. Shows `done / total`, the current
/// step name, a slim progress bar, and an "animated snake" border that
/// travels around the rounded rectangle while any step is in-progress.
/// Click expands a popover with the full checklist.
///
/// Observes `ACPTranscript` directly rather than `ACPSession` so the pill
/// re-renders when only the plan changes (`apply(.plan)` mutates
/// `transcript.messages` only; `ACPSession` does not forward
/// `transcript.objectWillChange`).
struct ACPPlanPill: View {
    @ObservedObject var transcript: ACPTranscript
    @Environment(\.theme) private var theme
    @State private var popoverOpen = false

    var body: some View {
        if let state = ACPPlanPillState(items: transcript.currentPlan) {
            pill(state: state)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func pill(state: ACPPlanPillState) -> some View {
        Button {
            popoverOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                statusDot(animating: state.isAnimating)
                Text("\(state.done) / \(state.total)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.color("accent"))
                Text(state.currentStep)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                progressBar(done: state.done, total: state.total)
                Image(systemName: popoverOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(pillBackground)
            .overlay(pillBorder(animating: state.isAnimating))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help("Plan — click to view all steps")
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            let items = transcript.currentPlan ?? []
            if let popoverState = ACPPlanPillState(items: items) {
                ACPPlanPopover(items: items, state: popoverState)
            }
        }
    }

    private var pillBackground: some View {
        LinearGradient(
            colors: [
                theme.color("accent").opacity(0.16),
                theme.color("accent").opacity(0.08)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    @ViewBuilder
    private func pillBorder(animating: Bool) -> some View {
        if animating {
            TimelineView(.animation) { context in
                let cycleSeconds: Double = 2.2
                let now = context.date.timeIntervalSinceReferenceDate
                let phase = (now.truncatingRemainder(dividingBy: cycleSeconds)) / cycleSeconds
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(snakeGradient(phase: phase), lineWidth: 1.25)
            }
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.color("accent").opacity(0.35), lineWidth: 1)
        }
    }

    private func snakeGradient(phase: Double) -> AngularGradient {
        let accent = theme.color("accent")
        let start = Angle.degrees(phase * 360.0)
        return AngularGradient(
            stops: [
                .init(color: .clear,             location: 0.00),
                .init(color: .clear,             location: 0.60),
                .init(color: accent.opacity(0.4),location: 0.75),
                .init(color: accent,             location: 0.88),
                .init(color: accent.opacity(0.4),location: 0.96),
                .init(color: .clear,             location: 1.00)
            ],
            center: .center,
            startAngle: start,
            endAngle: start + .degrees(360)
        )
    }

    @ViewBuilder
    private func statusDot(animating: Bool) -> some View {
        Circle()
            .fill(theme.color("accent"))
            .opacity(animating ? 1.0 : 0.4)
            .frame(width: 6, height: 6)
            .shadow(color: animating ? theme.color("accent").opacity(0.7) : .clear, radius: 3)
    }

    @ViewBuilder
    private func progressBar(done: Int, total: Int) -> some View {
        GeometryReader { geo in
            let ratio: Double = total > 0 ? Double(done) / Double(total) : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.color("fg-faint").opacity(0.18))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.color("accent"), theme.color("accent").opacity(0.6)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * CGFloat(ratio)))
            }
        }
        .frame(width: 48, height: 4)
    }
}

/// Popover body: full plan checklist, current step highlighted.
private struct ACPPlanPopover: View {
    let items: [ACPMessage.PlanItem]
    let state: ACPPlanPillState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(theme.color("line"))
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    row(item: item)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320)
        .background(theme.color("bg-1"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(theme.color("accent"))
            Text("Plan")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))
            Text("\(state.done) / \(state.total)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.4))
    }

    @ViewBuilder
    private func row(item: ACPMessage.PlanItem) -> some View {
        HStack(spacing: 10) {
            mark(for: item)
            Text(item.content)
                .font(.system(size: 12))
                .foregroundStyle(item.status == "completed" ? theme.color("fg-faint") : theme.color("fg"))
                .strikethrough(item.status == "completed", color: theme.color("fg-faint").opacity(0.5))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(item.status == "in_progress" ? theme.color("accent").opacity(0.10) : Color.clear)
    }

    @ViewBuilder
    private func mark(for item: ACPMessage.PlanItem) -> some View {
        switch item.status {
        case "completed":
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("add"))
                .frame(width: 12)
        case "in_progress":
            Spinner(lineWidth: 1.5, duration: 0.7)
                .frame(width: 10, height: 10)
                .frame(width: 12)
        default:
            Circle()
                .fill(theme.color("fg-faint").opacity(0.6))
                .frame(width: 5, height: 5)
                .frame(width: 12)
        }
    }
}
