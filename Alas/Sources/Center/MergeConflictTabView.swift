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
                gitService: GitService()
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
                    showBase: showBaseBinding,
                    wordDiffMode: Binding(
                        get: { model.wordDiffMode },
                        set: { model.wordDiffMode = $0 }
                    ),
                    baseAvailable: model.hasBase,
                    onPrevious: { model.previousConflict() },
                    onNext: { model.nextConflict() },
                    onAskAgentResolve: {
                        guard let agent = resolvedAgent else { return }
                        let template = state.config.changes.mergeSingleResolvePrompt
                        Task {
                            await model.requestAgentResolveFile(
                                using: agent,
                                template: template,
                                language: fileLanguage
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
                if let annotation = currentBlockAnnotation,
                   !annotation.isEmpty,
                   let key = currentBlockKey {
                    MergeConflictAnnotationStrip(
                        annotation: annotation,
                        conflictKey: key,
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
        .task {
            await model.load()
            // Kick off the first annotation fetch directly after load. The
            // `.onChange` hooks on `body3Columns` don't fire on initial
            // insertion, so without this call a single-conflict file
            // (where currentConflictIndex stays at 0 forever) would never
            // get auto-explained.
            triggerExplainIfNeeded()
            onStartupRecoveryReady()
        }
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
        .onChange(of: model.currentConflictIndex) { _, _ in
            triggerExplainIfNeeded()
        }
        .onChange(of: model.loadCompletionGeneration) { _, _ in
            triggerExplainIfNeeded()
        }
    }

    /// Fires `explainCurrentConflict` for the current conflict if there's
    /// an agent configured, a current conflict, and no cached annotation.
    /// The model dedupes against in-flight requests for the same block, so
    /// repeated calls from multiple `.onChange` hooks are safe.
    private func triggerExplainIfNeeded() {
        guard let agent = resolvedAgent,
              let ord = model.currentConflictIndex,
              let block = currentConflictBlock(at: ord),
              model.annotation(for: block) == nil
        else { return }
        Task {
            await model.explainCurrentConflict(using: agent, language: fileLanguage)
        }
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
        // Explicit "none" means the user disabled AI: respect that and never
        // auto-fire agent calls (auto-explain on conflict change, etc.).
        if id == "none" { return nil }
        if !id.isEmpty, let agent = state.agent(id: id) {
            return agent
        }
        return state.agentRegistry.enabled().first
    }

    /// Best-effort language label for the agent prompts. Returns nil for
    /// extension-less paths so the prompts omit the language hint.
    private var fileLanguage: String? {
        let ext = fileExtension
        return ext.isEmpty ? nil : ext
    }

    /// Annotation for the conflict the cursor is currently on, looked up by
    /// block-content identity (not ordinal) so it survives resolutions that
    /// renumber later conflicts.
    private var currentBlockAnnotation: String? {
        guard let ord = model.currentConflictIndex,
              let block = currentConflictBlock(at: ord)
        else { return nil }
        return model.annotation(for: block)
    }

    /// Identity for the current conflict block, used as the strip's
    /// dismissal key. Matches the content-hash key the model uses for
    /// caching annotations (`MergeConflictTabModel.annotationKey(for:)`)
    /// so dismissals survive positional shifts — edits above the block,
    /// resolving earlier conflicts — the same way the cached annotation
    /// itself does. Two blocks with byte-identical LOCAL/BASE/REMOTE
    /// in the same file share both the cached explanation and the
    /// dismissal state, which is consistent: the annotation cache is
    /// already aliased, so the dismissal aliases too.
    private var currentBlockKey: String? {
        guard let ord = model.currentConflictIndex,
              let block = currentConflictBlock(at: ord)
        else { return nil }
        return MergeConflictTabModel.annotationKey(for: block)
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
