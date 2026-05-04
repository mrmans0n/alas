import SwiftUI

struct TerminalTabView: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    let sessionId: String

    @Environment(\.theme) var theme

    var body: some View {
        Group {
            if let session = state.terminal.registry.session(for: sessionId) {
                GhosttyHost(session: session)
            } else {
                // Session was lost (likely after relaunch). Recreate.
                TerminalRecoverPlaceholder(state: state, worktreeId: worktreeId, tabId: tabId)
            }
        }
        .background(theme.color("bg-0"))
    }
}

private struct TerminalRecoverPlaceholder: View {
    @Bindable var state: AppState
    let worktreeId: String
    let tabId: TabID
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 12) {
            Text("Terminal closed")
                .font(.system(size: 14))
                .foregroundColor(theme.color("fg-muted"))
            AlasButton(title: "Open new terminal", style: .primary) {
                Task {
                    if let wt = currentWorktree() {
                        _ = try? state.openTerminalTab(for: wt)
                        state.closeTab(worktreeId: worktreeId, tabId: tabId)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-0"))
    }

    private func currentWorktree() -> Worktree? {
        for project in state.projects {
            if let wt = state.projectsManager.worktrees(projectId: project.id).first(where: { $0.id == worktreeId }) {
                return wt
            }
        }
        return nil
    }
}
