import SwiftUI

/// Toolbar pill that surfaces the ACP agent process lifecycle. Renders
/// nothing while the runner is `.idle` or `.ready` and a labeled chip
/// otherwise (spawning / disconnected / failed). Styled to sit next to
/// `ACPPlanPill` without clashing.
struct ACPRecoveryPill: View {
    @ObservedObject var session: ACPSession
    @Environment(\.theme) private var theme

    var body: some View {
        if let label = label(for: session.agentState) {
            HStack(spacing: 6) {
                statusDot(animating: isAnimating(session.agentState))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(theme.color("bg-1"))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .help(helpText(for: session.agentState))
            .transition(.opacity)
        }
    }

    private func label(for state: ACPSession.AgentState) -> String? {
        switch state {
        case .idle, .ready: return nil
        case .spawning: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Failed"
        }
    }

    private func helpText(for state: ACPSession.AgentState) -> String {
        switch state {
        case .spawning: return "Bringing the agent process back up…"
        case .disconnected: return "Agent process exited. Will reconnect on next send."
        case .failed(let reason): return "Failed: \(reason)"
        default: return ""
        }
    }

    private func isAnimating(_ state: ACPSession.AgentState) -> Bool {
        if case .spawning = state { return true }
        return false
    }

    @ViewBuilder
    private func statusDot(animating: Bool) -> some View {
        Circle()
            .fill(theme.color("accent"))
            .frame(width: 6, height: 6)
            .opacity(animating ? 0.4 : 1.0)
            .animation(animating
                ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                : .default,
                value: animating)
    }
}
