import AppKit
import SwiftUI

struct CenterPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    var allowsPaneFocus: Bool = true
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
                       let activity = state.harness.activityBySession[focusedSessionId] {
                        return (agent: activity.agent, state: activity.state)
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
                onNewTerminal: openTerminal,
                enabledAgents: state.agentRegistry.enabled(),
                onLaunchAgent: { agentId in
                    _ = try? state.openAgentTerminalTab(for: worktree, agentId: agentId)
                },
                onRevealRightSidebar: {
                    state.config.rightPaneVisible = true
                    state.saveConfig()
                },
                rightSidebarHidden: !state.config.rightPaneVisible,
                onRevealSidebar: {
                    state.config.sidebarVisible = true
                    state.saveConfig()
                },
                sidebarHidden: !state.config.sidebarVisible,
                onMove: { draggedId, destinationId in
                    state.tabs.moveTab(worktreeId: worktree.id, fromId: draggedId, toId: destinationId)
                },
                titleLookup: { id in
                    guard let tab = tabs.first(where: { $0.id == id }) else { return nil }
                    return state.tabs.displayTerminalTitle(for: tab)
                }
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
                                        tabId: tab.id,
                                        allowsPaneFocus: allowsPaneFocus)
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
                                            appState: state,
                                            onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) })
                        } else {
                            EditorTabView(worktreePath: worktree.path,
                                          relativePath: s.relativePath,
                                          worktreeId: worktree.id,
                                          tabId: s.id,
                                          revealLine: s.revealLine,
                                          revealCharacter: s.revealCharacter,
                                          appState: state,
                                          externalAbsolutePath: s.externalAbsolutePath,
                                          originatingRelativePath: s.originatingRelativePath,
                                          onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) })
                        }
                    case .diff(let s):
                        let openAvailable = DiffOpenFileAvailability.isAvailable(
                            worktreePath: worktree.path, relativePath: s.relativePath
                        )
                        let rps = state.rightPaneStore.state(
                            for: worktree,
                            baseBranch: state.config.worktrees.baseBranch
                        )
                        DiffTabView(
                            worktreePath: worktree.path,
                            relativePath: s.relativePath,
                            staged: s.staged,
                            codeFontFamily: state.config.code.fontFamily,
                            codeFontSize: CGFloat(state.config.code.fontSize),
                            onOpenFile: openAvailable
                                ? { state.openFile(relativePath: s.relativePath, worktreeId: worktree.id) }
                                : nil,
                            onRequestDiscardFile: {
                                rps.requestDiscardFile(path: s.relativePath)
                            }
                        )
                    case .commit(let s):
                        CommitTabView(
                            worktreePath: worktree.path,
                            sha: s.sha,
                            worktreeId: worktree.id,
                            appState: state
                        )
                        .id(s.sha)
                    case .commitEditor(let s):
                        CommitEditorTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: s,
                            appState: state
                        )
                        .id(s.id)
                    case .draftCommit(let draftState):
                        let _ = state.rightPaneStore.state(
                            for: worktree,
                            baseBranch: state.config.worktrees.baseBranch
                        )
                        DraftCommitTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: draftState,
                            appState: state
                        )
                        .id(draftState.id)
                    case .imagePreview(let s):
                        ImagePreviewTabView(worktreePath: worktree.path,
                                             relativePath: s.relativePath,
                                             onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) })
                    case .mergeConflict(let s):
                        MergeConflictTabView(
                            state: state,
                            worktree: worktree,
                            tabState: s
                        )
                        .id(s.id)
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
