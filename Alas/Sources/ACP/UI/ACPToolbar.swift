import SwiftUI

struct ACPToolbar: View {
    @ObservedObject var session: ACPSession
    let manager: ACPSessionManager
    let agentLookup: (String) -> AgentDefinition?
    let state: AppState
    let worktree: Worktree
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ACPSessionsButton(
                session: session,
                manager: manager,
                state: state,
                worktree: worktree,
                agentLookup: agentLookup
            )
            ACPMCPStatusControl(
                session: session,
                currentServers: state.projects.first(where: { $0.id == worktree.projectId })?.mcpServers ?? [],
                onInstallPiMCPAdapter: { await state.installPiMCPAdapter() },
                onSwitchToHTTP: {
                    state.config.harness.alasMCPTransport = .http
                    _ = state.saveConfig()
                    // A live session is `.ready`, for which `reattach` is a
                    // no-op — so detach then attach (the same flow as the
                    // explicit Reconnect action) to actually apply the new
                    // transport now instead of on some later disconnect.
                    Task {
                        await manager.detach(sessionId: session.id)
                        await manager.attach(to: session.id, freshlyCreated: false)
                    }
                }
            )
            ACPRecoveryPill(session: session)
            if let currentGoal = session.currentGoal {
                ACPGoalPill(goal: currentGoal)
            }
            ACPPlanPill(transcript: session.transcript)
                .layoutPriority(1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .background(
            LinearGradient(
                colors: [theme.color("bg-2").opacity(0.55), theme.color("bg-2").opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }
}

/// Small pulsing dot used as the "agent online" indicator. Lives in
/// the composer footer (left of the agent logo). Kept here because
/// nothing else owns it and the composer pulls it in by reference.
struct ACPPulseDot: View {
    let color: Color
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.20), lineWidth: 2))
            .shadow(color: color.opacity(0.55), radius: 4)
            .opacity(pulse ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
