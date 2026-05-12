import SwiftUI

/// Sidebar badge for harness activity.
/// - `.full` renders a pill `[• run]` / `[• wait]` for worktree rows.
/// - `.dotOnly` renders a bare colored dot for collapsed repo headers.
struct HarnessPill: View {
    enum Variant { case full, dotOnly }

    let summary: HarnessService.WorktreeHarnessSummary
    let variant: Variant
    let tooltip: String

    @Environment(\.theme) var theme

    var body: some View {
        switch variant {
        case .full:
            HStack(spacing: 4) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.color("bg-4"))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help(tooltip)

        case .dotOnly:
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .help(tooltip)
        }
    }

    private var dotColor: Color {
        switch summary.state {
        case .running:  return theme.color("add")
        case .awaiting: return theme.color("mod")
        }
    }

    private var label: String {
        switch summary.state {
        case .running:  return "run"
        case .awaiting: return "wait"
        }
    }
}
