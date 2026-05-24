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
        VStack(spacing: 0) {
            MergeConflictToolbar(
                conflictCount: model.conflictCount,
                currentConflictIndex: model.currentConflictIndex,
                // Binaries can't be resolved through the 3-column editor
                // (they're handled via the right-pane Use ours / Use theirs
                // context menu). Keep the resolve button disabled for them.
                isLoaded: model.conflictedFile != nil && model.conflictedFile?.isBinary == false,
                agentBusy: model.agentBusy,
                hasAgent: false,                 // wired in Task 6
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
                onAskAgentResolve: {},           // wired in Task 6
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
                    codeFontSize: CGFloat(state.config.code.fontSize)
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
                currentConflictIndex: model.currentConflictIndex,
                onJump: { idx in
                    // Clamp via repeated next/previous — the model's clamping
                    // logic ensures we land exactly on `idx` when reachable.
                    while (model.currentConflictIndex ?? 0) < idx { model.nextConflict() }
                    while (model.currentConflictIndex ?? 0) > idx { model.previousConflict() }
                }
            )
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
