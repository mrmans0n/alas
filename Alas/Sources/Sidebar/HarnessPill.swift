import SwiftUI

/// Sidebar badge for harness activity.
/// - `.full` renders a pill `[• run]` / `[• wait]` for worktree rows.
/// - `.dotOnly` renders a bare colored dot for collapsed repo headers.
struct HarnessPill: View {
    enum Variant { case full, dotOnly }

    let summary: HarnessService.WorktreeHarnessSummary
    let variant: Variant
    let tooltip: String
    var isSelected: Bool = false

    @Environment(\.theme) var theme

    var body: some View {
        switch variant {
        case .full:
            let background = isSelected ? theme.color("bg-3") : theme.color("bg-4")
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
            .background(background)
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

struct HarnessSessionBadge: View {
    let session: HarnessService.WorktreeHarnessSession
    let onActivate: () -> Void
    var isSelected = false

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onActivate) {
            Image(session.agent.logoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: 15, height: 15)
                .frame(width: 21, height: 21)
                .background(theme.color(isSelected ? "bg-3" : "bg-4"))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(theme.color(isSelected ? "bg-3" : "bg-4"), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var statusColor: Color {
        theme.color(session.state == .running ? "add" : "mod")
    }

    private var tooltip: String {
        "\(session.agent.displayName) · \(session.state == .running ? "running" : "waiting")"
    }
}
