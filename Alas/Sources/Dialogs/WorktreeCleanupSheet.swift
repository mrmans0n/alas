import SwiftUI

struct WorktreeCleanupSheet: View {
    @Bindable var model: WorktreeCleanupModel
    let showKeepBranchOption: Bool
    let onClose: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        DialogContainer(
            title: "Clean Up Worktrees",
            subtitle: subtitle,
            width: DialogContainerLayout.projectWidth,
            headerAccessory: {
                DialogHeaderIconButton(
                    icon: "arrow.clockwise",
                    tooltip: "Rescan worktrees"
                ) {
                    Task { await model.refresh() }
                }
                .disabled(model.isScanning || model.isRunning)
            },
            content: { content },
            cancelTitle: "Close",
            confirmTitle: "Delete Selected…",
            confirmStyle: .primary,
            onCancel: onClose,
            onConfirm: { Task { await model.deleteSelected() } },
            confirmEnabled: !model.selectedIds.isEmpty
                && !model.isRunning
                && !model.isScanning
                && model.scanError == nil
        )
    }

    private var subtitle: String? {
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
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                    Spacer()
                    AlasButton(title: "Retry", style: .normal) {
                        Task { await model.refresh() }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-2"))
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.rows.isEmpty {
                        Text(model.isScanning ? "Looking for worktrees…" : "No worktrees found.")
                            .font(.system(size: 12))
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach(model.rows) { row in
                        WorktreeCleanupRow(
                            row: row,
                            isSelected: model.selectedIds.contains(row.id),
                            isSelectionDisabled: model.isScanning,
                            result: model.results.first { $0.worktreeId == row.id },
                            onToggle: { model.toggle(row.id) }
                        )
                    }
                }
            }
            .frame(height: 320)

            if showKeepBranchOption {
                Toggle("Keep local branches", isOn: $model.keepBranches)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
            }

            HStack(spacing: 8) {
                AlasButton(title: "Archive Selected", style: .normal) {
                    Task { await model.archiveSelected() }
                }
                .disabled(
                    model.selectedIds.isEmpty
                        || model.isRunning
                        || model.isScanning
                        || model.scanError != nil
                )

                if !model.results.isEmpty {
                    Text(WorktreeCleanupModel.summary(for: model.results))
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
        }
    }
}

private struct WorktreeCleanupRow: View {
    let row: WorktreeCleanupRowState
    let isSelected: Bool
    let isSelectionDisabled: Bool
    let result: WorktreeBatchResult?
    let onToggle: () -> Void

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
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(theme.color("fg"))
                    if let candidate = row.candidate {
                        Text(verdictLabel(candidate.verdict))
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.color(verdictColor(candidate.verdict)).opacity(0.18))
                            )
                            .foregroundColor(theme.color(verdictColor(candidate.verdict)))
                    }
                    if row.isScanning {
                        Spinner(lineWidth: 1.4, duration: 0.8)
                            .frame(width: 11, height: 11)
                    }
                }
                Text(row.worktree.path.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let candidate = row.candidate {
                    ForEach(candidate.signals, id: \.self) { signal in
                        HStack(spacing: 5) {
                            Icon(
                                name: signal.isBlocking ? "x" : "check",
                                size: 9,
                                color: theme.color(signal.isBlocking ? "fg-muted" : "add")
                            )
                            Text(signal.label)
                                .font(.system(size: 11))
                                .foregroundColor(theme.color("fg-dim"))
                        }
                    }
                } else {
                    Text(row.isScanning ? "Checking merge state, changes, and activity…" : "Details unavailable")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-dim"))
                }

                if let result, let text = resultLabel(result) {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.color("del"))
                }
            }
            Spacer()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-2"))
        )
        .opacity(row.candidate?.isSelectable == false ? 0.6 : 1)
    }

    private func verdictLabel(_ verdict: WorktreeCleanupVerdict) -> String {
        switch verdict {
        case .candidate(.high):   return "Merged"
        case .candidate(.medium): return "Merged locally"
        case .candidate(.low):    return "Stale"
        case .busy:               return "Busy"
        case .dirty:              return "Has changes"
        case .active:             return "Active"
        case .excluded:           return "Excluded"
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
                    onClose: onClose
                )
            } else {
                ProgressView().controlSize(.small).padding(40)
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
