import SwiftUI

struct MergeConflictTabView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    let tabState: MergeConflictTabState

    @State private var model: MergeConflictTabModel
    @Environment(\.theme) var theme

    init(state: AppState, worktree: Worktree, tabState: MergeConflictTabState) {
        self.state = state
        self.worktree = worktree
        self.tabState = tabState
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
            VStack(spacing: 0) {
                MergeConflictToolbar(
                    conflictCount: model.conflictCount,
                    currentConflictIndex: model.currentConflictIndex,
                    currentAnnotation: currentBlockAnnotation,
                    isLoaded: model.conflictedFile != nil,
                    canRunAgent: model.conflictedFile != nil && model.conflictedFile?.isBinary == false,
                    agentBusy: model.agentBusy,
                    hasAgent: resolvedAgent != nil,
                    hasPendingProposal: model.agentProposal != nil,
                    showBase: showBaseBinding,
                    onPrevious: { model.previousConflict() },
                    onNext: { model.nextConflict() },
                    onAcceptLocal: { model.acceptLocal() },
                    onAcceptRemote: { model.acceptRemote() },
                    onAcceptBoth: { model.acceptBoth() },
                    onAcceptAndNext: {
                        model.acceptLocal()
                        model.nextConflict()
                    },
                    onAskAgentResolve: {
                        guard let agent = resolvedAgent else { return }
                        Task {
                            await model.requestAgentResolveFile(using: agent, language: fileLanguage)
                        }
                    },
                    onMarkResolved: {
                        Task {
                            try? await model.markFileResolved()
                            // The WorktreeWatcher on RightPaneState picks up the
                            // .git/index change from `git add` and refreshes the
                            // Conflicts section automatically — no explicit call
                            // is needed here.
                        }
                    }
                )
                content
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
        }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadError {
            errorBanner(loadError)
        } else if model.conflictedFile == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(spacing: 0) {
            // LOCAL
            VStack(spacing: 0) {
                columnHeader("LOCAL · ours")
                MergeConflictColumnView(
                    text: model.conflictedFile?.local ?? "",
                    fileExtension: fileExtension,
                    codeFontFamily: state.config.code.fontFamily,
                    codeFontSize: CGFloat(state.config.code.fontSize)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            // RESULT (editable)
            VStack(spacing: 0) {
                columnHeader("RESULT")
                MergeConflictResultView(
                    text: Binding(
                        get: { model.resultText },
                        set: { newValue in
                            model.resultText = newValue
                            model.reparse()
                        }
                    ),
                    fileExtension: fileExtension,
                    codeFontFamily: state.config.code.fontFamily,
                    codeFontSize: CGFloat(state.config.code.fontSize),
                    showBase: tabState.showBase
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            // REMOTE
            VStack(spacing: 0) {
                columnHeader("REMOTE · theirs")
                MergeConflictColumnView(
                    text: model.conflictedFile?.remote ?? "",
                    fileExtension: fileExtension,
                    codeFontFamily: state.config.code.fontFamily,
                    codeFontSize: CGFloat(state.config.code.fontSize)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            MergeConflictMinimap(
                conflictCount: model.conflictCount,
                resolvedCount: max(model.initialConflictCount - model.conflictCount, 0),
                currentConflictIndex: model.currentConflictIndex,
                onJump: { idx in
                    // Clamp via repeated next/previous — the model's clamping
                    // logic ensures we land exactly on `idx` when reachable.
                    while (model.currentConflictIndex ?? 0) < idx { model.nextConflict() }
                    while (model.currentConflictIndex ?? 0) > idx { model.previousConflict() }
                }
            )
        }
        .onChange(of: model.currentConflictIndex) { _, newIndex in
            guard let agent = resolvedAgent,
                  let ord = newIndex,
                  let block = currentConflictBlock(at: ord),
                  model.annotation(for: block) == nil
            else { return }
            Task {
                await model.explainCurrentConflict(using: agent, language: fileLanguage)
            }
        }
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .foregroundColor(theme.color("fg-dim"))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private var fileExtension: String {
        (tabState.relativePath as NSString).pathExtension
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
