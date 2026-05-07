import AppKit
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
                harnessLookup: { tabId in
                    if case .terminal(let s) = tabs.first(where: { $0.id == tabId }),
                       let kind = state.harness.harnessBySession[s.sessionId] {
                        let st = state.harness.stateBySession[s.sessionId] ?? "running"
                        return (kind: kind, state: st)
                    }
                    return nil
                },
                onActivate: { id in state.tabs.activate(worktreeId: worktree.id, tabId: id) },
                onClose:    { id in state.closeTab(worktreeId: worktree.id, tabId: id) },
                onCloseOthers: { id in state.closeOtherTabs(worktreeId: worktree.id, keeping: id) },
                onCloseAll: { state.closeAllTabs(worktreeId: worktree.id) },
                onCloseToLeft: { id in state.closeTabsToLeft(worktreeId: worktree.id, of: id) },
                onCloseToRight: { id in state.closeTabsToRight(worktreeId: worktree.id, of: id) },
                onCopyPath: { id in
                    guard let tab = tabs.first(where: { $0.id == id }),
                          let rel = tab.relativeFilePath else { return }
                    let absolute = worktree.path.appendingPathComponent(rel).path(percentEncoded: false)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(absolute, forType: .string)
                },
                onCopyRelativePath: { id in
                    guard let tab = tabs.first(where: { $0.id == id }),
                          let rel = tab.relativeFilePath else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(rel, forType: .string)
                },
                onNewTerminal: openTerminal
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
                                      relativePath: s.relativePath,
                                      worktreeId: worktree.id,
                                      tabId: s.id,
                                      revealLine: s.revealLine,
                                      revealCharacter: s.revealCharacter,
                                      appState: state)
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
