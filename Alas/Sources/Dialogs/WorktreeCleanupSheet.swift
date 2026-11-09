import SwiftUI

struct WorktreeCleanupSheet: View {
    @Environment(\.designScale) private var scale
    @Bindable var model: WorktreeCleanupModel
    let showKeepBranchOption: Bool
    let onOpenCheckout: (UUID) -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "Clean Up Worktrees",
            subtitle: subtitle,
            width: DialogContainerLayout.projectWidth,
            headerAccessory: {
                if model.isPreparingDelete || model.isRunning {
                    Spinner(lineWidth: 1.4, duration: 0.8)
                        .frame(width: 14, height: 14)
                }
                DialogHeaderIconButton(
                    icon: "arrow.clockwise",
                    tooltip: "Rescan worktrees"
                ) {
                    Task { await model.refresh() }
                }
                .disabled(model.isScanning || model.isPreparingDelete || model.isRunning)
            },
            content: { content },
            cancelTitle: "Close",
            confirmTitle: model.isPreparingDelete
                ? "Preparing…"
                : model.isRunning ? "Deleting…" : "Delete Selected…",
            confirmStyle: .primary,
            onCancel: onClose,
            onConfirm: { Task { await model.deleteSelected() } },
            confirmEnabled: !model.selectedIds.isEmpty
                && !model.isPreparingDelete
                && !model.isRunning
                && !model.isScanning
                && model.scanError == nil,
            cancelEnabled: !model.isPreparingDelete && !model.isRunning
        )
    }

    private var subtitle: String? {
        if model.isPreparingDelete {
            return "Checking deletion risks before confirmation…"
        }
        if model.isRunning {
            return "Deleting selected worktrees…"
        }
        if model.isScanning {
            guard let progress = model.scanProgress, progress.total > 0 else {
                return "Checking worktrees…"
            }
            return "Checking \(progress.completed) of \(progress.total) worktrees…"
        }
        if let error = model.scanError {
            return error
        }
        let candidates = model.candidates
        let count = candidates.filter(\.isSelectedByDefault).count
        return count == 0
            ? "Nothing looks ready to clean up."
            : "\(count) of \(candidates.count) look ready to clean up."
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.scanError {
                HStack(spacing: 8) {
                    Text(error)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                    Spacer()
                    AlasButton(title: "Retry", style: .normal) {
                        Task { await model.refresh() }
                    }
                }
                .padding(scale.space[2])
                .background(
                    RoundedRectangle(cornerRadius: scale.radius.medium).fill(theme.color("bg-2"))
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.rows.isEmpty {
                        Text(model.isScanning ? "Looking for worktrees…" : "No worktrees found.")
                            .font(scale.metaFont)
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, scale.space[2])
                    }
                    ForEach(model.rows) { row in
                        WorktreeCleanupRow(
                            row: row,
                            isSelected: model.selectedIds.contains(row.id),
                            isSelectionDisabled: model.isScanning
                                || model.isPreparingDelete
                                || model.isRunning,
                            result: model.results.first { $0.worktreeId == row.id },
                            onToggle: { model.toggle(row.id) },
                            onOpenCheckout: onOpenCheckout
                        )
                    }
                }
            }
            .frame(height: 320)

            if showKeepBranchOption {
                Toggle("Keep local branches", isOn: $model.keepBranches)
                    .font(scale.metaFont)
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 8) {
                AlasButton(title: "Archive Selected", style: .normal) {
                    Task { await model.archiveSelected() }
                }
                .disabled(
                    model.selectedIds.isEmpty
                        || model.isPreparingDelete
                        || model.isRunning
                        || model.isScanning
                        || model.scanError != nil
                )

                if !model.results.isEmpty {
                    Text(WorktreeCleanupModel.summary(for: model.results))
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
        }
    }
}

private struct WorktreeCleanupRow: View {
    @Environment(\.designScale) private var scale
    let row: WorktreeCleanupRowState
    let isSelected: Bool
    let isSelectionDisabled: Bool
    let result: WorktreeBatchResult?
    let onToggle: () -> Void
    let onOpenCheckout: (UUID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isSelectionDisabled || row.candidate?.isSelectable != true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.worktree.branch)
                        .font(scale.meta.font(weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    if let candidate = row.candidate {
                        Text(verdictLabel(candidate.verdict))
                            .font(scale.caption.font(weight: .medium))
                            .padding(.horizontal, scale.space[2]).padding(.vertical, 1) // design-literal: hairline inside the verdict pill
                            .background(
                                RoundedRectangle(cornerRadius: scale.radius.small)
                                    .fill(theme.color(verdictColor(candidate.verdict)).opacity(0.18))
                            )
                            .foregroundColor(theme.color(verdictColor(candidate.verdict)))
                    }
                    if row.isScanning {
                        Spinner(lineWidth: 1.4, duration: 0.8)
                            .frame(width: 11, height: 11)
                    }
                }
                Text(RemotePath.display(row.worktree.path.path))
                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let candidate = row.candidate {
                    ForEach(candidate.signals, id: \.self) { signal in
                        HStack(spacing: 5) {
                            Icon(
                                name: signal.isHardBlocker ? "x" : signal.isBlocking ? "alert" : "check",
                                size: 9,
                                color: theme.color(
                                    signal.isHardBlocker ? "del" : signal.isBlocking ? "mod" : "add"
                                )
                            )
                            Text(signal.label)
                                .font(scale.metaFont)
                                .foregroundColor(theme.color("fg-dim"))
                            if case .workspaceCheckout(let owner) = signal {
                                AlasButton(title: "Open Checkout", style: .normal) {
                                    onOpenCheckout(owner.id)
                                }
                                .disabled(isSelectionDisabled)
                                .opacity(isSelectionDisabled ? 0.5 : 1)
                            }
                        }
                    }
                } else {
                    Text(row.isScanning ? "Checking merge state, changes, and activity…" : "Details unavailable")
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                }

                if let result, let text = resultLabel(result) {
                    Text(text)
                        .font(scale.meta.font(weight: .medium))
                        .foregroundColor(theme.color("del"))
                }
            }
            Spacer()
        }
        .padding(.vertical, scale.space[2]).padding(.horizontal, scale.space[2])
        .background(
            RoundedRectangle(cornerRadius: scale.radius.medium).fill(theme.color("bg-2"))
        )
        .opacity(row.candidate?.isSelectable == false ? 0.6 : 1)
    }

    private func verdictLabel(_ verdict: WorktreeCleanupVerdict) -> String {
        if row.candidate?.isSelectable == true,
           row.candidate?.signals.contains(where: \.isBlocking) == true {
            return "Needs confirmation"
        }
        switch verdict {
        case .candidate(.high):   return "Merged"
        case .candidate(.medium): return "Merged locally"
        case .candidate(.low):    return "Stale"
        case .busy:               return "Blocked"
        case .dirty:              return "Has changes"
        case .active:             return "Active"
        case .excluded:           return "Blocked"
        }
    }

    private func verdictColor(_ verdict: WorktreeCleanupVerdict) -> String {
        switch verdict {
        case .candidate: return "add"
        case .busy:      return "mod"
        case .dirty:     return "del"
        case .active:    return "fg-muted"
        case .excluded:  return "fg-muted"
        }
    }

    private func resultLabel(_ result: WorktreeBatchResult) -> String? {
        switch result.outcome {
        case .deleted, .archived:      return nil
        case .failed(let message):     return "Failed: \(message)"
        case .needsForce:              return "Needs force delete — remove it individually"
        case .skipped(let reason):     return "Skipped: \(reason)"
        }
    }
}

/// Owns the model for the lifetime of the sheet so a body re-evaluation does
/// not rebuild it and restart the scan.
struct WorktreeCleanupSheetHost: View {
    let state: AppState
    let projectId: String
    let onClose: () -> Void

    @State private var model: WorktreeCleanupModel?

    var body: some View {
        Group {
            if let model {
                WorktreeCleanupSheet(
                    model: model,
                    showKeepBranchOption: state.config.worktrees.deleteBranchOnRemove,
                    onOpenCheckout: { checkoutID in
                        state.selectWorkspaceCheckout(id: checkoutID)
                        onClose()
                    },
                    onClose: onClose
                )
            } else {
                ProgressView().controlSize(.small).padding(40) // design-literal: spinner placeholder breathing room
            }
        }
        .task {
            guard model == nil else { return }
            guard let built = state.makeWorktreeCleanupModel(projectId: projectId) else {
                onClose()
                return
            }
            model = built
            await built.refresh()
        }
    }
}
