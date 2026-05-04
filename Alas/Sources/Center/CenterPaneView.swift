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
                onNewEditor: { _ = state.tabs.appendEditor(worktreeId: worktree.id, title: "untitled", relativePath: "") },
                onNewDiff:   { _ = state.tabs.appendDiff(worktreeId: worktree.id, title: "untitled", relativePath: "") }
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
                    case .editor(let s):
                        EditorTabView(worktreePath: worktree.path,
                                      relativePath: s.relativePath)
                    case .diff(let s):
                        DiffTabView(worktreePath: worktree.path,
                                    relativePath: s.relativePath)
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
