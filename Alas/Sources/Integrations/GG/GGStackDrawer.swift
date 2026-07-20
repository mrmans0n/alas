import SwiftUI

struct GGStackDrawer: View {
    @Bindable var rps: RightPaneState
    let appState: AppState

    @Environment(\.theme) private var theme
    @State private var expanded = false
    @State private var isRefreshing = false

    private var model: GGStackReadinessModel? {
        if let stack = rps.ggStack {
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
                )
            )
        }
        return GGStackReadinessModel.makePausedFallback(action: rps.ggActionState)
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
        }
    }

    private func collapsedRow(_ model: GGStackReadinessModel) -> some View {
        HStack(spacing: 7) {
            Circle().fill(theme.color(model.isPaused ? "warn" : "accent")).frame(width: 6, height: 6)
            Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
            Text(model.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundColor(theme.color("fg-muted")).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(model.summaryChip)
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(theme.color("fg-dim"))
            if isRefreshing {
                Spinner(lineWidth: 1.4, duration: 0.8).frame(width: 11, height: 11)
            } else {
                Button {
                    isRefreshing = true
                    let task = rps.reevaluateGGGate()
                    Task { @MainActor in
                        await task.value
                        isRefreshing = false
                    }
                } label: {
                    Icon(name: "arrow.clockwise", size: 10, color: theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(rps.ggActionState.inFlightAction != nil)
                .help("Refresh stack and PR status")
            }
            Icon(name: expanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
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
        .accessibilityLabel(model.title)
        .accessibilityHint(expanded ? "Collapse stack status" : "Expand stack status")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            expanded.toggle()
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
                ForEach(model.actions) { action in
                    Button {
                        if action.kind == .land { rps.requestGGLand(.ready) }
                        else { rps.onGGStackAction(action.kind, appState: appState) }
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
            }
        }
        .scrollIndicators(.hidden)
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
