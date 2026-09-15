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
    /// E1's agent tile size. `WorktreeRowView` sizes its "+N" overflow
    /// control to match so the badge group stays on one baseline.
    static let diameter: CGFloat = 17
    static let logoSize: CGFloat = 12
    static let cornerRadius: CGFloat = 5.5

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
                .frame(width: Self.logoSize, height: Self.logoSize)
                .frame(width: Self.diameter, height: Self.diameter)
                .modifier(HarnessSessionBadgeChrome(state: session.state, isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }

    private var tooltip: String {
        "\(session.agent.displayName) · \(session.state == .running ? "running" : "waiting")"
    }
}

struct HarnessSessionBadgeChrome: ViewModifier {
    let state: HarnessService.AggregatedState
    var isSelected = false

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                    .strokeBorder(borderColor, lineWidth: 0.75)
            )
            .overlay {
                if state == .running {
                    RoundedRectangle(cornerRadius: HarnessSessionBadge.cornerRadius)
                        .strokeBorder(theme.color("add").opacity(0.20), lineWidth: 2)
                        .blur(radius: 2)
                }
            }
            // E1 lifts the tile off the row with a soft drop shadow.
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }

    private var fillColor: Color {
        switch state {
        case .running:
            return theme.color("add").opacity(isSelected ? 0.12 : 0.08)
        case .awaiting:
            return theme.color("caution").opacity(isSelected ? 0.14 : 0.10)
        }
    }

    private var borderColor: Color {
        switch state {
        case .running:
            return theme.color("add").opacity(0.55)
        case .awaiting:
            return theme.color("caution").opacity(0.60)
        }
    }
}
