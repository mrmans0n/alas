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
                       let focusedSessionId = s.root.find(leafId: s.focusedLeafId)?.leaf.sessionId,
                       let kind = state.harness.harnessBySession[focusedSessionId] {
                        let st = state.harness.stateBySession[focusedSessionId] ?? "running"
                        return (kind: kind, state: st)
                    }
                    return nil
                },
                dirtyLookup: { id in
                    let buffer = state.tabs.peekBuffer(tabId: id)
                    // Touch editGeneration so SwiftUI's Observation tracker
                    // re-evaluates this closure on every keystroke; without
                    // this, `dirty` (which depends on non-observable
                    // NSTextStorage) would only refresh on theme/tab changes.
                    _ = buffer?.editGeneration
                    return buffer?.dirty ?? false
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
                onRenameTerminal: { id in
                    state.renameTerminalTab(worktreeId: worktree.id, tabId: id)
                },
                onNewTerminal: openTerminal
            )
            Group {
                if tabs.isEmpty {
                    EmptyTabView(onNewTerminal: openTerminal)
                } else if let activeId = active,
                          let tab = tabs.first(where: { $0.id == activeId }) {
                    switch tab {
                    case .terminal:
                        TerminalTabView(state: state,
                                        worktreeId: worktree.id,
                                        tabId: tab.id)
                    case .editor(let s):
                        if MarkdownFileType.isMarkdown(relativePath: s.isExternal
                                                        ? (s.externalAbsolutePath ?? "")
                                                        : s.relativePath) {
                            MarkdownTabView(worktreePath: worktree.path,
                                            worktreeId: worktree.id,
                                            tabId: s.id,
                                            relativePath: s.relativePath,
                                            externalAbsolutePath: s.externalAbsolutePath,
                                            originatingRelativePath: s.originatingRelativePath,
                                            revealLine: s.revealLine,
                                            revealCharacter: s.revealCharacter,
                                            appState: state)
                        } else {
                            EditorTabView(worktreePath: worktree.path,
                                          relativePath: s.relativePath,
                                          worktreeId: worktree.id,
                                          tabId: s.id,
                                          revealLine: s.revealLine,
                                          revealCharacter: s.revealCharacter,
                                          appState: state,
                                          externalAbsolutePath: s.externalAbsolutePath,
                                          originatingRelativePath: s.originatingRelativePath)
                        }
                    case .diff(let s):
                        DiffTabView(worktreePath: worktree.path,
                                    relativePath: s.relativePath,
                                    staged: s.staged)
                    case .commit(let s):
                        CommitTabView(
                            worktreePath: worktree.path,
                            sha: s.sha,
                            appState: state
                        )
                        .id(s.sha)
                    case .imagePreview(let s):
                        ImagePreviewTabView(worktreePath: worktree.path,
                                            relativePath: s.relativePath)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.color("bg-1"))
    }

    private func openTerminal() {
        _ = try? state.openTerminalTab(for: worktree)
    }
}
