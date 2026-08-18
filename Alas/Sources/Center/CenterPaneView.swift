import AppKit
import SwiftUI

enum CenterTabNavigationDirection: Sendable {
    case previous
    case next
}

struct CenterTabComposition {
    let tabs: [Tab]
    let activeId: TabID?

    init(
        worktreeTabs: [Tab],
        activeWorktreeTabId: TabID?
    ) {
        tabs = worktreeTabs
        if worktreeTabs.contains(where: { $0.id == activeWorktreeTabId }) {
            activeId = activeWorktreeTabId
        } else if activeWorktreeTabId != nil {
            activeId = worktreeTabs.first?.id
        } else {
            activeId = nil
        }
    }

    var activeTab: Tab? {
        guard let activeId else { return nil }
        return tabs.first { $0.id == activeId }
    }

    func adjacentTabID(in direction: CenterTabNavigationDirection) -> TabID? {
        guard tabs.count > 1,
              let activeId,
              let activeIndex = tabs.firstIndex(where: { $0.id == activeId }) else { return nil }
        let offset: Int
        switch direction {
        case .previous: offset = -1
        case .next: offset = 1
        }
        let targetIndex = (activeIndex + offset + tabs.count) % tabs.count
        return tabs[targetIndex].id
    }
}

struct CenterTabClosurePlan {
    let orderedTabIDs: [TabID]

    func others(keeping tabID: TabID) -> [TabID] {
        orderedTabIDs.filter { $0 != tabID }
    }

    func all() -> [TabID] {
        orderedTabIDs
    }

    func left(of tabID: TabID) -> [TabID] {
        guard let index = orderedTabIDs.firstIndex(of: tabID) else { return [] }
        return Array(orderedTabIDs[..<index])
    }

    func right(of tabID: TabID) -> [TabID] {
        guard let index = orderedTabIDs.firstIndex(of: tabID) else { return [] }
        return Array(orderedTabIDs[orderedTabIDs.index(after: index)...])
    }
}

enum StartupRecoveryPaneCompletionPolicy {
    static func shouldComplete(activeTab: Tab?) -> Bool {
        switch activeTab {
        case .terminal, .editor, .diff, .stashDiff, .commit, .commitEditor, .draftCommit,
             .draftReviewRequest, .reviewChanges, .reviewSession, .imagePreview,
             .mergeConflict, .acpSession, .reviewPR, .fileSnapshot, .fileHistory,
             .ggInbox, .ggSplitCommit:
            false
        default:
            true
        }
    }
}

struct CenterPaneView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    var allowsPaneFocus: Bool = true
    @Environment(\.theme) var theme
    @State private var startupRecoveryReadyTabID: TabID?

    var body: some View {
        VStack(spacing: 0) {
            let worktreeTabs = state.tabs.tabs(forWorktree: worktree.id)
            let composition = CenterTabComposition(
                worktreeTabs: worktreeTabs,
                activeWorktreeTabId: state.tabs.activeTabId(forWorktree: worktree.id)
            )
            let tabs = composition.tabs
            let closurePlan = CenterTabClosurePlan(orderedTabIDs: tabs.map(\.id))
            TabBarView(
                tabs: tabs,
                activeId: composition.activeId,
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
                    // The closure is consumed by the per-tab close button,
                    // so the invalidation is scoped to that tiny view
                    // instead of the whole tab bar.
                    _ = buffer?.editGeneration
                    return buffer?.dirty ?? false
                },
                onActivate: { state.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: $0) },
                onClose: { state.requestCloseTab(worktreeId: worktree.id, tabId: $0) },
                onCloseOthers: { id in
                    state.closeCenterTabs(worktreeId: worktree.id, tabIds: closurePlan.others(keeping: id))
                },
                onCloseAll: {
                    state.closeCenterTabs(worktreeId: worktree.id, tabIds: closurePlan.all())
                },
                onCloseToLeft: { id in
                    state.closeCenterTabs(worktreeId: worktree.id, tabIds: closurePlan.left(of: id))
                },
                onCloseToRight: { id in
                    state.closeCenterTabs(worktreeId: worktree.id, tabIds: closurePlan.right(of: id))
                },
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
                onOpenWithSystem: { id in
                    guard !worktree.path.isRemoteAlasPath,
                          let tab = tabs.first(where: { $0.id == id }) else { return }
                    let url: URL
                    if let abs = tab.absoluteFilePath {
                        url = URL(fileURLWithPath: abs)
                    } else if let rel = tab.relativeFilePath {
                        url = worktree.path.appendingPathComponent(rel)
                    } else {
                        return
                    }
                    FileSystemOpen.open(url: url)
                },
                onRevealInFinder: { id in
                    guard !worktree.path.isRemoteAlasPath,
                          let tab = tabs.first(where: { $0.id == id }) else { return }
                    let url: URL
                    if let abs = tab.absoluteFilePath {
                        url = URL(fileURLWithPath: abs)
                    } else if let rel = tab.relativeFilePath {
                        url = worktree.path.appendingPathComponent(rel)
                    } else {
                        return
                    }
                    FileSystemOpen.reveal(url: url)
                },
                revisionFollowCapability: { tab in
                    let supportsStackEntry = state.ggFollowSupported(worktreeID: worktree.id)
                    switch tab {
                    case .commit(let state):
                        return RevisionFollowCapability(
                            isSupported: true,
                            isFollowing: state.revision.tracked != nil,
                            supportsStackEntry: supportsStackEntry
                        )
                    case .reviewSession(let state):
                        let record = try? ReviewSessionStore().load(id: state.sessionID)
                        guard record?.target.kind == .commit || record?.target.kind == .trackedCommit else {
                            return RevisionFollowCapability(isSupported: false, isFollowing: false)
                        }
                        let isFollowing: Bool
                        if case .trackedCommit = record?.target.payload {
                            isFollowing = true
                        } else {
                            isFollowing = false
                        }
                        return RevisionFollowCapability(
                            isSupported: true,
                            isFollowing: isFollowing,
                            supportsStackEntry: supportsStackEntry
                        )
                    default:
                        return RevisionFollowCapability(isSupported: false, isFollowing: false)
                    }
                },
                onFollowRevision: { id in
                    state.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: id)
                    state.promptFollowRevision(worktreeID: worktree.id, tabID: id)
                },
                onFollowStackEntry: { id in
                    state.promptFollowStackEntry(worktreeID: worktree.id, tabID: id)
                },
                onEditRevision: { id in
                    let prefill: TrackedRevisionTarget? = {
                        switch tabs.first(where: { $0.id == id }) {
                        case .commit(let s):
                            return s.revision.tracked?.target
                        case .reviewSession(let s):
                            let record = try? ReviewSessionStore().load(id: s.sessionID)
                            if case .trackedCommit(let revision) = record?.target.payload {
                                return revision.target
                            }
                            return nil
                        default:
                            return nil
                        }
                    }()
                    state.activateWorktreeCenterTab(worktreeId: worktree.id, tabId: id)
                    state.promptFollowRevision(worktreeID: worktree.id, tabID: id, prefill: prefill)
                },
                onStopFollowingRevision: { id in
                    state.stopFollowingRevision(worktreeID: worktree.id, tabID: id)
                },
                systemActionsEnabled: !worktree.path.isRemoteAlasPath,
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
                    Task { @MainActor in
                        _ = try? await state.openAgentTerminalTabPreparingRemoteZmxIfNeeded(for: worktree, agentId: agentId)
                    }
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
                loadRunScripts: { RunScriptStore.scripts(worktreeRoot: worktree.path) },
                isScriptRunning: { script in state.runningScriptTab(for: script, in: worktree) != nil },
                onRunScript: { script in state.runOrFocusScript(script, in: worktree) },
                onRestartScript: { script in state.restartScript(script, in: worktree) },
                onNewRunScript: { scope in state.newRunScript(scope: scope, in: worktree) },
                onEditScripts: { state.openRunScriptPaletteOverlay(mode: .edit) },
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
            .onAppear {
                state.synchronizeVisibleWorktreeCenterTabIfNeeded(
                    worktreeId: worktree.id,
                    activeTabId: composition.activeId
                )
            }
            .onChange(of: composition.activeId) { _, activeId in
                state.synchronizeVisibleWorktreeCenterTabIfNeeded(
                    worktreeId: worktree.id,
                    activeTabId: activeId
                )
            }
            let runScriptFailures = state.runScriptFailures(in: worktree.id)
                .sorted { $0.completedAt > $1.completedAt }
            Group {
                if tabs.isEmpty, !state.tabs.hasLoaded {
                    Spinner()
                } else if tabs.isEmpty {
                    EmptyTabView(
                        onNewTerminal: openTerminal,
                        onNewAgentInChat: { state.openAgentLauncherOverlay(.locked(.acp)) },
                        onNewAgentInTerminal: { state.openAgentLauncherOverlay(.locked(.terminal)) },
                        newTerminalShortcut: state.binding(for: .newTerminalTab)?.displayString,
                        newAgentInChatShortcut: state.binding(for: .launchAgentInChat)?.displayString,
                        newAgentInTerminalShortcut: state.binding(for: .launchAgentInTerminal)?.displayString
                    )
                } else if let activeId = composition.activeId,
                          let tab = tabs.first(where: { $0.id == activeId }) {
                    switch tab {
                    case .terminal:
                        TerminalTabView(state: state,
                                        worktreeId: worktree.id,
                                        tabId: tab.id,
                                        allowsPaneFocus: allowsPaneFocus,
                                        onStartupRecoveryReady: { completeStartupRecoveryIfActive(tab.id) })
                    case .editor(let s):
                        if MarkdownFileType.supportsRichPreview(relativePath: s.isExternal
                                                                 ? (s.externalAbsolutePath ?? "")
                                                                 : s.relativePath) {
                            MarkdownTabView(worktreePath: worktree.path,
                                            worktreeId: worktree.id,
                                            tabId: s.id,
                                            relativePath: s.relativePath,
                                            externalAbsolutePath: s.externalAbsolutePath,
                                            externalEditable: s.isExternalEditable,
                                            originatingRelativePath: s.originatingRelativePath,
                                            revealLine: s.revealLine,
                                            revealEndLine: s.revealEndLine,
                                            revealCharacter: s.revealCharacter,
                                            revealRevision: s.revealRevision,
                                            appState: state,
                                            onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) },
                                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) })
                        } else {
                            EditorTabView(worktree: worktree,
                                          worktreePath: worktree.path,
                                          relativePath: s.relativePath,
                                          worktreeId: worktree.id,
                                          tabId: s.id,
                                          revealLine: s.revealLine,
                                          revealEndLine: s.revealEndLine,
                                          revealCharacter: s.revealCharacter,
                                          revealRevision: s.revealRevision,
                                          appState: state,
                                          externalAbsolutePath: s.externalAbsolutePath,
                                          externalEditable: s.isExternalEditable,
                                          originatingRelativePath: s.originatingRelativePath,
                                          onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) },
                                          onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) })
                        }
                    case .diff(let s):
                        let openAvailable = DiffOpenFileAvailability.isAvailable(
                            worktreePath: worktree.path, relativePath: s.relativePath
                        )
                        DiffTabView(
                            worktreePath: worktree.path,
                            relativePath: s.relativePath,
                            staged: s.staged,
                            originalPath: s.originalPath,
                            compareWithHEAD: s.compareWithHEAD,
                            worktreeId: worktree.id,
                            appState: state,
                            codeFontFamily: state.config.code.fontFamily,
                            codeFontSize: CGFloat(state.config.code.fontSize),
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) },
                            onOpenFile: openAvailable
                                ? { state.openFile(relativePath: s.relativePath, worktreeId: worktree.id) }
                                : nil,
                            onRequestDiscardFile: {
                                let rps = state.rightPaneStore.activeState(worktreeId: worktree.id)
                                    ?? activateRightPaneStateForCenterTab()
                                rps.requestDiscardFile(path: s.relativePath)
                            }
                        )
                        .id(s.id)
                        .task(id: rightPaneActivationKey) {
                            activateRightPaneStateForCenterTab()
                        }
                    case .stashDiff(let s):
                        StashDiffTabView(
                            worktreePath: worktree.path,
                            state: s,
                            codeFontFamily: state.config.code.fontFamily,
                            codeFontSize: CGFloat(state.config.code.fontSize),
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                        .id(s.id)
                    case .commit(let s):
                        CommitTabView(
                            worktreePath: worktree.path,
                            tabState: s,
                            worktreeId: worktree.id,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                        .id(s.viewID)
                    case .commitEditor(let s):
                        CommitEditorTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: s,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                        .id(s.id)
                    case .draftCommit(let draftState):
                        DraftCommitTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: draftState,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(draftState.id) }
                        )
                        .id(draftState.presentationID)
                        .task(id: rightPaneActivationKey) {
                            activateRightPaneStateForCenterTab()
                        }
                    case .draftReviewRequest(let draftState):
                        DraftReviewRequestTabView(
                            worktreePath: worktree.path,
                            worktreeId: worktree.id,
                            tabState: draftState,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(draftState.id) }
                        )
                        .id(draftState.id)
                    case .reviewChanges(let reviewState):
                        ReviewChangesTabView(
                            worktree: worktree,
                            tabState: reviewState,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(reviewState.id) }
                        )
                        .id(reviewState.id)
                        .task(id: rightPaneActivationKey) {
                            activateRightPaneStateForCenterTab()
                        }
                    case .reviewPR(let prState):
                        ReviewTabView(
                            worktree: worktree,
                            tabState: prState,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(prState.id) }
                        )
                        .id(prState.id)
                        .task(id: rightPaneActivationKey) {
                            activateRightPaneStateForCenterTab()
                        }
                    case .reviewSession(let sessionState):
                        ReviewSessionTabView(
                            worktree: worktree,
                            tabState: sessionState,
                            appState: state,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(sessionState.id) }
                        )
                        .id(sessionState.viewID)
                    case .imagePreview(let s):
                        ImagePreviewTabView(worktreePath: worktree.path,
                                             relativePath: s.relativePath,
                                             onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) },
                                             onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) })
                    case .binaryPreview(let s):
                        BinaryPreviewTabView(worktreePath: worktree.path,
                                             relativePath: s.relativePath,
                                             onRevealInFiles: { path in state.revealInFiles(worktreeId: worktree.id, path: path) })
                    case .mergeConflict(let s):
                        MergeConflictTabView(
                            state: state,
                            worktree: worktree,
                            tabState: s,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                        .id(s.id)
                    case .fileSnapshot(let s):
                        FileSnapshotTabView(
                            worktreePath: worktree.path,
                            state: s,
                            codeFontFamily: state.config.code.fontFamily,
                            codeFontSize: CGFloat(state.config.code.fontSize),
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                    case .fileHistory(let s):
                        FileHistoryTabView(
                            worktreePath: worktree.path,
                            state: s,
                            onSelectCommit: { state.openCommitTab(worktreeId: worktree.id, commit: $0) },
                            onCopySHA: { Clipboard.copy($0.sha) },
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                    case .acpSession(let s):
                        ACPTabView(
                            sessionId: s.sessionId,
                            state: state,
                            worktree: worktree,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                            .id(s.id)
                    case .ggInbox(let s):
                        GGInboxTabView(
                            state: state,
                            tabState: s,
                            onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                        )
                            .id(s.id)
                    case .ggSplitCommit(let s):
                        let capabilities = GGAvailability.shared.capabilities
                        if let rightPaneState = state.rightPaneStore.activeState(worktreeId: worktree.id) {
                            let hasBlockingGitOperation = rightPaneState.mergeOp.current != nil
                            let ggActionState = rightPaneState.ggActionState
                            let targetEntry = s.targetEntry(in: rightPaneState.ggStack)
                            // A `.split` in flight for *this tab's own target* is its
                            // own Apply; it stays "available" (the view manages it via
                            // `isApplying`) so the workflowAvailable-keyed `.id` below
                            // doesn't recreate the editor mid-apply and discard its
                            // inline error. Any other in-flight mutation — including a
                            // split started from a different tab — still gates it off.
                            let ownSplitApplying = ggActionState.inFlightAction == .split
                                && (rightPaneState.activeSplitTargetIdentity
                                    .map { s.matches(splitTarget: $0) } ?? false)
                            let otherActionInFlight = ggActionState.inFlightAction != nil
                                && !ownSplitApplying
                            let workflowAvailable = rightPaneState.ggContext.isActive
                                && targetEntry != nil
                                && targetEntry?.prState != .merged
                                && !otherActionInFlight
                                && ggActionState.pausedOperation == nil
                            GGSplitCommitTabView(
                                tabState: s,
                                worktreePath: worktree.path,
                                rightPaneState: rightPaneState,
                                capabilities: capabilities,
                                workflowAvailable: workflowAvailable,
                                hasBlockingGitOperation: hasBlockingGitOperation,
                                completesStartupRecoveryWhenUnavailable: Self
                                    .shouldCompleteGGSplitStartupRecoveryWhenUnavailable(
                                        hasLoadedSnapshot: rightPaneState.hasLoadedSnapshot,
                                        ggStackLoadState: rightPaneState.ggStackLoadState,
                                        ggAvailabilityHasProbed: GGAvailability.shared.hasProbed
                                    ),
                                initialDraft: state.tabs.ggSplitCommitDraft(worktreeId: worktree.id, tabId: s.id),
                                codeFontFamily: state.config.code.fontFamily,
                                codeFontSize: CGFloat(state.config.code.fontSize),
                                onCancel: {
                                    state.tabs.close(worktreeId: worktree.id, tabId: s.id)
                                },
                                onDraftChange: { draft in
                                    state.tabs.updateGGSplitCommitDraft(
                                        worktreeId: worktree.id,
                                        tabId: s.id,
                                        draft: draft
                                    )
                                },
                                onStartupRecoveryReady: { completeStartupRecoveryIfActive(s.id) }
                            )
                            .id("\(s.id):\(capabilities.structuredSplit):\(workflowAvailable):\(hasBlockingGitOperation)")
                            .task(id: rightPaneActivationKey) {
                                activateRightPaneStateForCenterTab()
                            }
                        } else {
                            ProgressView()
                                .task(id: rightPaneActivationKey) {
                                    activateRightPaneStateForCenterTab()
                                }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Choose a Tab",
                        systemImage: "rectangle.stack",
                        description: Text("No tab was reopened after the previous session ended unexpectedly.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if !runScriptFailures.isEmpty {
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(runScriptFailures, id: \.id) { failure in
                            RunScriptFailureBanner(
                                presentation: RunScriptFailureBannerPresentation(failure: failure),
                                onOpen: { state.presentRunScriptFailure(failure) },
                                onDismiss: { state.dismissRunScriptFailure(id: failure.id, worktreeID: worktree.id) }
                            )
                            .frame(width: 360)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onAppear {
            completeStartupRecoveryIfPaneIsStable()
        }
        .onChange(of: state.tabs.hasLoaded) { _, _ in
            completeStartupRecoveryIfPaneIsStable()
        }
        .onChange(of: state.tabs.activeTabId(forWorktree: worktree.id)) { _, _ in
            startupRecoveryReadyTabID = nil
            completeStartupRecoveryIfPaneIsStable()
        }
        .onChange(of: rightPaneStartupRecoveryReady) { _, _ in
            completeStartupRecoveryIfPaneIsStable()
        }
        .background(theme.color("bg-1"))
        .sheet(item: $state.selectedRunScriptFailure) { failure in
            RunScriptFailureDetailView(failure: failure)
        }
    }

    private func completeStartupRecoveryIfPaneIsStable() {
        guard state.tabs.hasLoaded else { return }
        let composition = CenterTabComposition(
            worktreeTabs: state.tabs.tabs(forWorktree: worktree.id),
            activeWorktreeTabId: state.tabs.activeTabId(forWorktree: worktree.id)
        )
        guard Self.shouldCompleteStartupRecoveryForCenterPane(
            activeTab: composition.activeTab,
            readyTabID: startupRecoveryReadyTabID
        ) else { return }
        guard rightPaneStartupRecoveryReady else { return }
        state.completeStartupRecovery()
    }

    private var rightPaneStartupRecoveryReady: Bool {
        let rightPaneState = state.rightPaneStore.activeState(worktreeId: worktree.id)
        return Self.shouldCompleteStartupRecoveryForRightPane(
            isRightPaneVisible: state.config.rightPaneVisible,
            hasLoadedSnapshot: rightPaneState?.hasLoadedSnapshot ?? false,
            isLoading: rightPaneState?.loading ?? false
        )
    }

    static func shouldCompleteStartupRecoveryForRightPane(
        isRightPaneVisible: Bool,
        hasLoadedSnapshot: Bool,
        isLoading: Bool
    ) -> Bool {
        !isRightPaneVisible || (hasLoadedSnapshot && !isLoading)
    }

    static func shouldCompleteStartupRecoveryForCenterPane(
        activeTab: Tab?,
        readyTabID: TabID?
    ) -> Bool {
        StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: activeTab) || activeTab?.id == readyTabID
    }

    static func shouldCompleteGGSplitStartupRecoveryWhenUnavailable(
        hasLoadedSnapshot: Bool,
        ggStackLoadState: GGStackLoadState,
        ggAvailabilityHasProbed: Bool
    ) -> Bool {
        hasLoadedSnapshot && ggAvailabilityHasProbed && ggStackLoadState != .loading
    }

    private func completeStartupRecoveryIfActive(_ tabID: TabID) {
        guard state.selectedWorktreeId == worktree.id else { return }
        let composition = CenterTabComposition(
            worktreeTabs: state.tabs.tabs(forWorktree: worktree.id),
            activeWorktreeTabId: state.tabs.activeTabId(forWorktree: worktree.id)
        )
        guard composition.activeId == tabID else { return }
        startupRecoveryReadyTabID = tabID
        guard rightPaneStartupRecoveryReady else { return }
        state.completeStartupRecovery()
    }

    private var rightPaneActivationKey: String {
        "\(worktree.id)\u{0000}\(worktree.branch)\u{0000}\(state.config.worktrees.baseBranch)\u{0000}\(state.config.changes.comparisonMode.rawValue)"
    }

    @discardableResult
    private func activateRightPaneStateForCenterTab() -> RightPaneState {
        state.rightPaneStore.state(
            for: worktree,
            baseBranch: state.config.worktrees.baseBranch,
            comparisonMode: state.config.changes.comparisonMode
        )
    }

    private func openTerminal() {
        Task { @MainActor in
            _ = try? await state.openTerminalTabPreparingRemoteZmxIfNeeded(for: worktree)
        }
    }
}
