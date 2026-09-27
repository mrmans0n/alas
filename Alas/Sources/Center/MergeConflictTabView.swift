import SwiftUI

struct MergeConflictTabView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let tabState: MergeConflictTabState
    let onStartupRecoveryReady: () -> Void

    @State private var model: MergeConflictTabModel
    /// Conflict keys dismissed from the annotation strip. Lifted out of
    /// `MergeConflictAnnotationStrip` so dismissal survives navigating
    /// to a conflict that has no cached annotation (which would unmount
    /// the strip and otherwise reset its local @State).
    @State private var dismissedAnnotationKeys: Set<String> = []
    @Environment(\.theme) var theme

    init(
        state: AppState,
        worktree: Worktree,
        tabState: MergeConflictTabState,
        onStartupRecoveryReady: @escaping () -> Void = {}
    ) {
        self.state = state
        self.worktree = worktree
        self.tabState = tabState
        self.onStartupRecoveryReady = onStartupRecoveryReady
        self._model = State(
            initialValue: MergeConflictTabModel(
                worktreePath: worktree.path,
                relativePath: tabState.relativePath,
                gitService: GitService(),
                agentBinaryUnavailable: { [state, worktree] target in
                    guard case .ssh = target else { return }
                    state.agentAvailabilityStore.invalidate(
                        target: target,
                        worktreePath: worktree.path.path
                    )
                    await state.loadAgentAvailability(for: worktree)
                }
            )
        )
    }

    var body: some View {
        ZStack {
            if model.notInConflictedState {
                MergeConflictResolvedEmptyView(
                    relativePath: tabState.relativePath,
                    onOpenFile: {
                        state.openFile(
                            relativePath: tabState.relativePath,
                            worktreeId: worktree.id
                        )
                    },
                    onCloseTab: {
                        state.closeTab(
                            worktreeId: worktree.id,
                            tabId: tabState.id
                        )
                    }
                )
            } else {
            VStack(spacing: 0) {
                MergeConflictToolbar(
                    conflictCount: model.conflictCount,
                    currentConflictIndex: model.currentConflictIndex,
                    isLoaded: model.conflictedFile != nil,
                    canRunAgent: model.conflictedFile != nil && model.conflictedFile?.isBinary == false,
                    agentBusy: model.agentBusy,
                    hasAgent: resolvedAgent != nil,
                    hasPendingProposal: model.agentProposal != nil,
                    explainAvailable: explainer.isAvailable,
                    canExplain: model.conflictedFile?.isBinary == false && currentBlock.map { block in
                        model.explanation(for: block) == nil
                            || dismissedAnnotationKeys.contains(MergeConflictTabModel.conflictKey(for: block))
                    } == true,
                    isExplaining: model.explainingKey != nil && model.explainingKey == currentBlockKey,
                    showBase: showBaseBinding,
                    wordDiffMode: Binding(
                        get: { model.wordDiffMode },
                        set: { model.wordDiffMode = $0 }
                    ),
                    baseAvailable: model.hasBase,
                    onPrevious: { model.previousConflict() },
                    onNext: { model.nextConflict() },
                    onExplain: {
                        if let key = currentBlockKey {
                            dismissedAnnotationKeys.remove(key)
                        }
                        let explainer = explainer
                        Task { await model.explainCurrentConflict(using: explainer) }
                    },
                    onAskAgentResolve: {
                        guard let agent = resolvedAgent else { return }
                        let template = state.config.changes.mergeSingleResolvePrompt
                        Task {
                            await model.requestAgentResolveFile(
                                using: agent,
                                template: template,
                                language: fileLanguage,
                                target: agentExecutionTarget
                            )
                        }
                    },
                    onMarkResolved: {
                        Task {
                            do {
                                try await model.markFileResolved()
                                // Explicit refresh + tab close so the user
                                // gets immediate feedback that the file
                                // moved out of Conflicts. The FSEvents
                                // watcher would catch up eventually, but
                                // the debouncer + watcher latency made the
                                // change feel sticky.
                                await state.rightPaneStore.refresh(worktreeId: worktree.id)
                                state.closeTab(worktreeId: worktree.id, tabId: tabState.id)
                            } catch {
                                // markResolved is best-effort; the gitService
                                // logs the underlying error.
                            }
                        }
                    }
                )
                if let block = currentBlock,
                   let ordinal = model.currentConflictIndex,
                   let explanation = model.explanation(for: block) {
                    MergeConflictAnnotationStrip(
                        explanation: explanation,
                        citation: MergeConflictExplanationPolicy.citation(
                            conflictNumber: ordinal + 1,
                            conflictCount: model.conflictCount,
                            lineRange: block.lineRangeInMerged
                        ),
                        localLabel: block.localLabel,
                        remoteLabel: block.remoteLabel,
                        conflictKey: MergeConflictTabModel.conflictKey(for: block),
                        dismissedKeys: $dismissedAnnotationKeys
                    )
                }
                content
            }
            }
            if let proposal = model.agentProposal {
                MergeConflictAgentProposalView(
                    currentText: model.resultText,
                    proposedText: proposal,
                    fileExtension: fileExtension,
                    codeFontFamily: state.config.code.fontFamily,
                    codeFontSize: CGFloat(state.config.code.fontSize),
                    onApply: { model.applyAgentProposal() },
                    onCancel: { model.discardAgentProposal() }
                )
                .transition(.opacity)
            }
        }
        // Trigger a fresh load every time the view appears, not just on
        // first mount. `TabsManager.openMergeConflict` re-uses an existing
        // tab for the same path, so re-focusing after a second conflict on
        // the same file must re-read the three sides to avoid showing stale
        // resultText/regions from the prior conflict.
        .task(id: agentAvailabilityTaskID) {
            await state.loadAgentAvailability(for: worktree)
        }
        .task {
            await model.load()
            onStartupRecoveryReady()
        }
        .onDisappear { model.cancelExplanation() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadError {
            errorBanner(loadError)
        } else if model.conflictedFile == nil {
            Spinner()
                .frame(width: 20, height: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.conflictedFile?.isBinary == true {
            MergeConflictBinaryView(
                conflictedFile: model.conflictedFile!,
                worktreePath: worktree.path,
                loadGeneration: model.loadGeneration
            )
        } else {
            body3Columns
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
            Spacer()
            Button("Reload") {
                Task { await model.load() }
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
    }

    private var body3Columns: some View {
        MergeView3Way(
            model: model,
            fileExtension: fileExtension,
            codeFontFamily: state.config.code.fontFamily,
            codeFontSize: CGFloat(state.config.code.fontSize),
            showBase: model.hasBase && tabState.showBase,
            onJumpToConflict: { idx in
                while (model.currentConflictIndex ?? 0) < idx { model.nextConflict() }
                while (model.currentConflictIndex ?? 0) > idx { model.previousConflict() }
            }
        )
    }

    private var fileExtension: String {
        LanguageRegistry.highlighterExtension(forPath: tabState.relativePath)
    }

    /// Resolves the agent to use for merge-conflict assistance. Prefers the
    /// user's pinned tool from Settings → Changes → AI tool, then falls back
    /// to any enabled agent. Returns nil when the user explicitly chose
    /// "none" (AI disabled) or when no agents are configured.
    private var resolvedAgent: AgentDefinition? {
        let id = state.config.changes.aiToolId
        if id == "none" { return nil }
        let agents = state.agentAvailability(for: worktree).agents
        if !id.isEmpty, let agent = agents.first(where: { $0.id == id }) {
            return agent
        }
        if !id.isEmpty {
            return nil
        }
        return agents.first
    }

    private var agentExecutionTarget: AgentExecutionTarget {
        state.agentExecutionTarget(for: worktree)
    }

    private var agentAvailabilityTaskID: String {
        "\(agentExecutionTarget)\u{0000}\(worktree.path.path)\u{0000}\(state.agentAvailabilityGeneration(for: worktree))"
    }

    /// Best-effort language label for the agent prompts. Returns nil for
    /// extension-less paths so the prompts omit the language hint.
    private var fileLanguage: String? {
        let ext = fileExtension
        return ext.isEmpty ? nil : ext
    }

    private var explainer: MergeConflictExplainer {
        state.makeMergeConflictExplainer()
    }

    private var currentBlock: ConflictBlock? {
        model.currentConflictIndex.flatMap(currentConflictBlock(at:))
    }

    private var currentBlockKey: String? {
        currentBlock.map(MergeConflictTabModel.conflictKey(for:))
    }

    /// Returns the `ConflictBlock` for the Nth unresolved conflict, or nil.
    private func currentConflictBlock(at ordinal: Int) -> ConflictBlock? {
        var seen = 0
        for region in model.regions {
            if case .conflict(let block) = region {
                if seen == ordinal { return block }
                seen += 1
            }
        }
        return nil
    }

    /// Writes the BASE-toggle back through TabsManager so the preference
    /// persists per-tab across app restarts.
    private var showBaseBinding: Binding<Bool> {
        Binding(
            get: { tabState.showBase },
            set: { newValue in
                state.tabs.updateMergeConflict(
                    worktreeId: tabState.worktreeId,
                    tabId: tabState.id
                ) { mutableState in
                    mutableState.showBase = newValue
                }
            }
        )
    }
}
