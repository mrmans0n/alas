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
                onClose:    { id in state.requestCloseTab(worktreeId: worktree.id, tabId: id) },
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
                onRenameACPSession: { id in
                    state.renameACPSessionTab(worktreeId: worktree.id, tabId: id)
                },
                onCopyACPSession: { id in
                    state.copyACPSessionMarkdown(worktreeId: worktree.id, tabId: id)
                },
                onExportACPSession: { id in
                    state.exportACPSessionMarkdown(worktreeId: worktree.id, tabId: id)
                },
                onNewTerminal: openTerminal,
                enabledAgents: state.agentRegistry.enabled(),
                onLaunchAgent: { agentId in
                    _ = try? state.openAgentTerminalTab(for: worktree, agentId: agentId)
                },
                onLaunchACPSession: { agentId in
                    state.openNewACPSession(agentID: agentId)
                },
                acpAgents: {
                    // Only enabled builtins with a wired ACP launch spec.
                    let enabledIds = Set(state.agentRegistry.enabled().map(\.id))
                    return ACPLaunchCatalog.specs.compactMap { spec in
                        guard enabledIds.contains(spec.agentID) else { return nil }
                        return AgentBuiltins.entry(id: spec.agentID)
                    }
                }(),
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
                    if case .acpSession(let s) = tab,
                       let mgr = state.acpManager(forWorktreeId: worktree.id),
                       let session = mgr.sessions[s.sessionId] {
                        let t = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        return t.isEmpty ? nil : t
                    }
                    return state.tabs.displayTerminalTitle(for: tab)
                },
                transcriptLookup: { id in
                    guard let tab = tabs.first(where: { $0.id == id }),
                          case .acpSession(let s) = tab,
                          let mgr = state.acpManager(for: worktree),
                          let session = mgr.placeholderSession(id: s.sessionId) else { return nil }
                    return session.transcript
                },
                acpAgentLookup: { id in
                    guard let tab = tabs.first(where: { $0.id == id }),
                          case .acpSession(let s) = tab,
                          let mgr = state.acpManager(forWorktreeId: worktree.id),
                          let session = mgr.sessions[s.sessionId] else { return nil }
                    return state.agent(id: session.agentId)
                        ?? AgentBuiltins.entry(id: session.agentId)
                }
            )
            Group {
                if tabs.isEmpty, !state.tabs.hasLoaded {
                    Spinner()
                } else if tabs.isEmpty {
                    EmptyTabView(
                        onNewTerminal: openTerminal,
                        onNewAgentTerminal: { state.openAgentLauncherOverlay(mode: .terminal) },
                        onNewAgentChat: { state.openAgentLauncherOverlay(mode: .acp) },
                        newTerminalShortcut: state.binding(for: .newTerminalTab)?.displayString,
                        newAgentTerminalShortcut: state.binding(for: .launchAgentTerminal)?.displayString,
                        newAgentChatShortcut: state.binding(for: .launchAgentChat)?.displayString
                    )
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
                            baseBranch: state.config.worktrees.baseBranch,
                            trackUpstreamForCommits: state.config.changes.trackUpstreamForCommits
                        )
                        DiffTabView(
                            worktreePath: worktree.path,
                            relativePath: s.relativePath,
                            staged: s.staged,
                            appState: state,
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
                            baseBranch: state.config.worktrees.baseBranch,
                            trackUpstreamForCommits: state.config.changes.trackUpstreamForCommits
                        )
                        DraftCommitTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: draftState,
                            appState: state
                        )
                        .id(draftState.id)
                    case .draftReviewRequest(let draftState):
                        DraftReviewRequestTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: draftState,
                            appState: state
                        )
                        .id(draftState.id)
                    case .reviewEvidence(let evidenceState):
                        let _ = state.rightPaneStore.state(
                            for: worktree,
                            baseBranch: state.config.worktrees.baseBranch,
                            trackUpstreamForCommits: state.config.changes.trackUpstreamForCommits
                        )
                        ReviewEvidenceTabView(
                            worktreePath: worktree.path,
                            tabState: evidenceState,
                            appState: state
                        )
                        .id(evidenceState.id)
                    case .reviewChanges(let reviewState):
                        ReviewChangesTabView(
                            worktree: worktree,
                            tabState: reviewState,
                            appState: state
                        )
                        .id(reviewState.id)
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
                    case .acpSession(let s):
                        ACPTabView(sessionId: s.sessionId, state: state, worktree: worktree)
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
