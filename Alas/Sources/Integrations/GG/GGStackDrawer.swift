import SwiftUI

struct GGStackPlaceholderModel: Equatable {
    let title: String
    let summaryChip: String
    let detail: String?
    let canRetry: Bool
    let isLoading: Bool

    var isExpandable: Bool { detail != nil || canRetry }

    static func make(
        context: GGWorktreeContext,
        loadState: GGStackLoadState
    ) -> GGStackPlaceholderModel? {
        guard case .active(let stackName) = context else { return nil }

        switch loadState {
        case .loading:
            return GGStackPlaceholderModel(
                title: stackName,
                summaryChip: "Loading",
                detail: nil,
                canRetry: false,
                isLoading: true
            )
        case .empty:
            return GGStackPlaceholderModel(
                title: stackName,
                summaryChip: "0 commits",
                detail: nil,
                canRetry: false,
                isLoading: false
            )
        case .failed(let message):
            return GGStackPlaceholderModel(
                title: stackName,
                summaryChip: "Unavailable",
                detail: message,
                canRetry: true,
                isLoading: false
            )
        case .inactive, .loaded:
            return nil
        }
    }
}

struct GGStackDrawer: View {
    @Bindable var rps: RightPaneState
    let appState: AppState

    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var isRefreshing = false

    private var model: GGStackReadinessModel? {
        if rps.ggStackLoadState == .loaded, let stack = rps.ggStack {
            return GGStackReadinessModel.make(
                stack: stack,
                action: rps.ggActionState,
                liveBehindBase: Self.liveBehindBaseOverride(
                    stack: stack,
                    selectedBaseBranch: rps.baseBranch,
                    behindBase: rps.behindBase
                ),
                hasBlockingGitOperation: Self.hasBlockingGitOperation(
                    mergeOperation: rps.mergeOp.current,
                    pausedGGOperation: rps.ggActionState.pausedOperation
                ),
                effectiveConfig: rps.ggEffectiveConfig,
                localChanges: rps.ggLocalChangeStatistics,
                undoCandidate: rps.ggUndoCandidate
            )
        }
        if rps.ggActionState.pausedOperation == nil, rps.ggUndoCandidate != nil {
            let inFlight = rps.ggActionState.inFlightAction
            return GGStackReadinessModel(
                title: "Stack recovery",
                summaryChip: "undo available",
                facts: [],
                primaryActions: [GGStackReadinessModel.Action(
                    kind: .undo,
                    title: "Undo Last GG Operation",
                    detail: nil,
                    isEnabled: inFlight == nil,
                    isInFlight: inFlight == .undo,
                    emphasis: .primary
                )],
                overflowActions: [],
                progressRows: [],
                isPaused: false,
                actionSummary: rps.ggActionState.lastActionSummary,
                localChangesNote: nil
            )
        }
        return GGStackReadinessModel.makePausedFallback(action: rps.ggActionState)
    }

    private var placeholderModel: GGStackPlaceholderModel? {
        GGStackPlaceholderModel.make(
            context: rps.ggContext,
            loadState: rps.ggStackLoadState
        )
    }

    static func liveBehindBaseOverride(
        stack: GGStack,
        selectedBaseBranch: String,
        behindBase: GitService.BehindStatus?
    ) -> Int? {
        guard selectedBaseBranch == stack.base else { return nil }
        return behindBase?.count
    }

    static func hasBlockingGitOperation(
        mergeOperation: MergeOperation?,
        pausedGGOperation: GGPausedOperation?
    ) -> Bool {
        mergeOperation != nil && pausedGGOperation == nil
    }

    var body: some View {
        if let model {
            VStack(spacing: 0) {
                Rectangle().fill(theme.color("accent").opacity(0.24)).frame(height: 1)
                collapsedRow(model)
                if expanded { expandedBody(model) }
            }
            .background(theme.color("bg-1").opacity(0.97))
        } else if let placeholderModel {
            VStack(spacing: 0) {
                Rectangle().fill(theme.color("accent").opacity(0.24)).frame(height: 1)
                collapsedRow(placeholderModel)
                if expanded { expandedBody(placeholderModel) }
            }
            .background(theme.color("bg-1").opacity(0.97))
        }
    }

    private func collapsedRow(_ model: GGStackReadinessModel) -> some View {
        expandableCollapsedRow(
            title: model.title,
            summaryChip: model.summaryChip,
            isPaused: model.isPaused,
            showsLoading: false
        )
    }

    @ViewBuilder
    private func collapsedRow(_ model: GGStackPlaceholderModel) -> some View {
        if model.isExpandable {
            expandableCollapsedRow(
                title: model.title,
                summaryChip: model.summaryChip,
                isPaused: false,
                showsLoading: model.isLoading
            )
        } else {
            staticCollapsedRow(
                title: model.title,
                summaryChip: model.summaryChip,
                showsLoading: model.isLoading
            )
        }
    }

    private func expandableCollapsedRow(
        title: String,
        summaryChip: String,
        isPaused: Bool,
        showsLoading: Bool
    ) -> some View {
        collapsedRowContent(
            title: title,
            summaryChip: summaryChip,
            isPaused: isPaused,
            showsLoading: showsLoading,
            showsChevron: true
        )
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            expanded.toggle()
            return .handled
        }
        .onKeyPress(.space) {
            expanded.toggle()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(expanded ? "Collapse stack status" : "Expand stack status")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            expanded.toggle()
        }
    }

    private func staticCollapsedRow(
        title: String,
        summaryChip: String,
        showsLoading: Bool
    ) -> some View {
        collapsedRowContent(
            title: title,
            summaryChip: summaryChip,
            isPaused: false,
            showsLoading: showsLoading,
            showsChevron: false
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func collapsedRowContent(
        title: String,
        summaryChip: String,
        isPaused: Bool,
        showsLoading: Bool,
        showsChevron: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Circle().fill(theme.color(isPaused ? "warn" : "accent")).frame(width: 6, height: 6)
            Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundColor(theme.color("fg-muted")).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(summaryChip)
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(theme.color("fg-dim"))
            Button {
                appState.openGGInbox(projectId: rps.worktree.projectId)
            } label: {
                Icon(name: "tray.full", size: 10, color: theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Open gg inbox")
            refreshControl(showsLoading: showsLoading)
            if showsChevron {
                Icon(name: expanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    @ViewBuilder
    private func refreshControl(showsLoading: Bool) -> some View {
        if showsLoading || isRefreshing {
            Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 11, height: 11)
        } else {
            Button(action: refresh) {
                Icon(name: "arrow.clockwise", size: 10, color: theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(rps.ggActionState.inFlightAction != nil)
            .help("Refresh stack and PR status")
        }
    }

    @ViewBuilder
    private func expandedBody(_ model: GGStackPlaceholderModel) -> some View {
        if model.detail != nil || model.canRetry {
            VStack(alignment: .leading, spacing: 8) {
                if let detail = model.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("warn"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.canRetry {
                    Button("Retry", action: refresh)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isRefreshing)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func expandedBody(_ model: GGStackReadinessModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isPaused {
                if !model.progressRows.isEmpty { progressList(model) }
                Text("A gg operation is paused on conflicts. Resolve them in the Conflicts section, then Continue — or Abort to roll back.")
                    .font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
                if let err = rps.ggActionState.lastError {
                    Text(err).font(.system(size: 11)).foregroundColor(theme.color("warn")).lineLimit(3)
                }
                actionRow(model)
                actionDetails(model)
                factsView(model)
            } else if !model.progressRows.isEmpty {
                progressList(model)
            } else {
                if let summary = model.actionSummary {
                    Text(summary).font(.system(size: 11)).foregroundColor(theme.color("add"))
                }
                if let err = rps.ggActionState.lastError {
                    Text(err).font(.system(size: 11)).foregroundColor(theme.color("warn")).lineLimit(3)
                }
                actionRow(model)
                actionDetails(model)
                factsView(model)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func progressList(_ model: GGStackReadinessModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.progressRows.enumerated()), id: \.offset) { _, row in
                Text(row).font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
            }
        }
    }

    private func actionRow(_ model: GGStackReadinessModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.primaryActions) { action in
                    Button {
                        perform(action)
                    } label: {
                        HStack(spacing: 6) {
                            if action.isInFlight { Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10) }
                            Text(action.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundColor(action.emphasis == .primary ? theme.color("bg-0") : theme.color("fg-muted"))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(action.emphasis == .primary ? theme.color("accent") : theme.color("bg-3").opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(!action.isEnabled)
                    .opacity(action.isEnabled || action.isInFlight ? 1 : 0.5)
                    .help(action.title)
                }
                if !model.overflowActions.isEmpty {
                    Menu {
                        ForEach(model.overflowActions) { action in
                            Button(action.title) { perform(action) }
                                .disabled(!action.isEnabled)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.color("fg-muted"))
                            .frame(width: 26, height: 26)
                            .background(theme.color("bg-3").opacity(0.72))
                            .clipShape(.rect(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
                    .help("Stack actions")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func actionDetails(_ model: GGStackReadinessModel) -> some View {
        if let detail = model.primaryActions.first?.detail {
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-dim"))
        }
        if let note = model.localChangesNote {
            Text(note)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("warn"))
        }
    }

    private func perform(_ action: GGStackReadinessModel.Action) {
        if action.kind == .land {
            rps.requestGGLand(.ready)
        } else {
            rps.onGGStackAction(action.kind, appState: appState)
        }
    }

    private func refresh() {
        isRefreshing = true
        let task = rps.reevaluateGGGate()
        Task { @MainActor in
            await task.value
            isRefreshing = false
        }
    }

    private func factsView(_ model: GGStackReadinessModel) -> some View {
        VStack(spacing: 4) {
            ForEach(model.facts) { fact in
                HStack(spacing: 8) {
                    Text(fact.label).font(.system(size: 10.5)).foregroundColor(theme.color("fg-faint"))
                    Spacer(minLength: 8)
                    Text(fact.value).font(.system(size: 10.5, weight: .semibold)).foregroundColor(theme.color("fg-dim"))
                }
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.color("bg-2").opacity(0.48)))
            }
        }
    }
}
