import SwiftUI

struct ACPToolbar: View {
    @ObservedObject var session: ACPSession
    let manager: ACPSessionManager
    let agentLookup: (String) -> AgentDefinition?
    let state: AppState
    let worktree: Worktree
    var owner: SessionOwnerID? = nil
    var onOpenPreview: (() -> Void)? = nil
    var onSummarizeSession: (() -> Void)? = nil
    var isSummarizingSession = false
    @Environment(\.theme) private var theme
    @State private var previewHovered = false
    @State private var summaryHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ACPSessionsButton(
                session: session,
                manager: manager,
                state: state,
                worktree: worktree,
                owner: owner,
                agentLookup: agentLookup
            )
            ACPMCPStatusControl(
                session: session,
                currentServers: state.mcpServersForACPToolbar(worktree: worktree, owner: owner),
                onInstallPiMCPAdapter: { await state.installPiMCPAdapter() },
                onSwitchToHTTP: isWorkspaceCheckoutOwner ? nil : {
                    state.config.harness.alasMCPTransport = .http
                    _ = state.saveConfig()
                    reconnectSession()
                },
                onReconnect: reconnectSession,
                onToggleRepoServer: { name, toggle in
                    switch toggle {
                    case .disable:
                        state.setRepoMCPServerDisabled(
                            projectId: worktree.projectId,
                            name: name,
                            disabled: true
                        )
                    case .enable:
                        state.setRepoMCPServerDisabled(
                            projectId: worktree.projectId,
                            name: name,
                            disabled: false
                        )
                    case .approve:
                        state.approveRepoMCPServer(
                            projectId: worktree.projectId,
                            worktreeRoot: worktree.path,
                            name: name
                        )
                    }
                }
            )
            ACPRecoveryPill(session: session)
            if let currentGoal = session.currentGoal {
                ACPGoalPill(goal: currentGoal)
            }
            ACPPlanPill(transcript: session.transcript)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let onSummarizeSession {
                Button(action: onSummarizeSession) {
                    HStack(spacing: 5) {
                        if isSummarizingSession {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        Text(isSummarizingSession ? "Summarizing" : "Summarize")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.color(summaryHovered ? "fg" : "fg-muted"))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        summaryHovered ? theme.color("bg-3") : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.toolbarControl)
                .onHover { summaryHovered = $0 }
                .disabled(isSummarizingSession)
                .help("Generate an on-device session catch-up")
                .accessibilityLabel("Summarize session")
                .accessibilityIdentifier("acp-summarize-session")
            }
            if let onOpenPreview {
                Button(action: onOpenPreview) {
                    HStack(spacing: 5) {
                        Icon(name: "globe", size: 11)
                        Text("Preview")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(theme.color(previewHovered ? "fg" : "fg-muted"))
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        previewHovered ? theme.color("bg-3") : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.toolbarControl)
                .onHover { previewHovered = $0 }
                .help("Open checkout web preview")
                .accessibilityLabel("Open checkout web preview")
                .accessibilityIdentifier("checkout-open-preview")
            }
            ToolbarBtn(
                icon: "rectangle.trailingthird.inset.filled",
                tooltip: state.config.harness.acpShowMinimap ? "Hide minimap" : "Show minimap",
                isActive: state.config.harness.acpShowMinimap
            ) {
                state.config.harness.acpShowMinimap.toggle()
                state.saveConfig()
            }
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

    private var isWorkspaceCheckoutOwner: Bool {
        if case .workspaceCheckout = owner { return true }
        return false
    }

    private func reconnectSession() {
        Task {
            await manager.detach(sessionId: session.id)
            await manager.attach(to: session.id, freshlyCreated: false)
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
