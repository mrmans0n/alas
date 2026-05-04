import SwiftUI

struct CenterPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            let tabs = state.tabs.tabs(forWorktree: worktree.id)
            let active = state.tabs.activeTabId(forWorktree: worktree.id)
            TabBarView(
                tabs: tabs,
                activeId: active,
                onActivate: { id in state.tabs.activate(worktreeId: worktree.id, tabId: id) },
                onClose:    { id in state.closeTab(worktreeId: worktree.id, tabId: id) },
                onNewTerminal: openTerminal,
                onNewEditor:   {},     // wired in Plan 4
                onNewDiff:     {}      // wired in Plan 4
            )
            Group {
                if tabs.isEmpty {
                    EmptyTabView(onNewTerminal: openTerminal)
                } else if let activeId = active,
                          let tab = tabs.first(where: { $0.id == activeId }) {
                    switch tab {
                    case .terminal(let s):
                        TerminalTabView(state: state,
                                        worktreeId: worktree.id,
                                        tabId: tab.id,
                                        sessionId: s.sessionId)
                    case .editor:
                        Text("Editor coming in Plan 4").foregroundColor(theme.color("fg-dim"))
                    case .diff:
                        Text("Diff coming in Plan 4").foregroundColor(theme.color("fg-dim"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.color("bg-1"))
    }

    private func openTerminal() {
        try? state.openTerminalTab(for: worktree)
    }
}
