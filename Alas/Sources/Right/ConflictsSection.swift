import SwiftUI

struct ConflictsSection: View {
    let conflicts: [ChangedFile]
    /// True while the workspace-level agent invocation is running. The
    /// resolve button flips into Cancel and a spinner row appears below
    /// the header.
    let bulkInFlight: Bool
    /// Final outcome of the last bulk-resolve run. Surfaced as a
    /// transient banner the user can dismiss.
    let bulkReport: BulkConflictResolveReport?
    /// True when at least one enabled AI tool is configured for the
    /// Changes section. Gates the bulk action — disabled with a tooltip
    /// otherwise.
    let hasAgent: Bool
    let onSelect: (ChangedFile) -> Void
    let onUseOurs: (ChangedFile) -> Void
    let onUseTheirs: (ChangedFile) -> Void
    let onKeepDeleted: (ChangedFile) -> Void
    let onMarkResolved: (ChangedFile) -> Void
    /// Triggered by the section-header bulk-resolve button.
    let onResolveAllWithAgent: () -> Void
    /// Triggered while a bulk resolve is in flight; the same button
    /// flips into a cancel action.
    let onCancelBulkResolve: () -> Void
    /// Triggered when the user closes the post-run banner.
    let onDismissBulkReport: () -> Void
    var dragPayload: ((ChangedFile) -> DragOutPayload?)? = nil

    @State private var pendingBothDeletedConfirm: ChangedFile?

    var body: some View {
        // Keep the section mounted while a bulk run is in flight too,
        // so the spinner + Cancel stay visible even if conflicts drop
        // to zero mid-run (e.g. an intermediate refresh after the
        // agent stages a file).
        if conflicts.isEmpty, bulkReport == nil, !bulkInFlight {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 2) {
                header
                if bulkInFlight {
                    progressRow
                }
                if let report = bulkReport {
                    reportRow(report)
                }
                ForEach(conflicts) { file in
                    row(for: file)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Conflicts (\(conflicts.count))")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(.secondary)
            Spacer()
            bulkResolveButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var bulkResolveButton: some View {
        if bulkInFlight {
            Button(action: onCancelBulkResolve) {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle")
                    Text("Cancel")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.red)
        } else if !conflicts.isEmpty {
            Button(action: onResolveAllWithAgent) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("Resolve all with agent")
                }
                .font(.system(size: 10))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(!hasAgent)
            .help(hasAgent
                ? "Run the configured agent across every text conflict and stage the results"
                : "Pick an agent in Settings → Changes that supports non-interactive permission bypass (e.g. Claude, Codex, Cursor)")
        }
    }

    private var progressRow: some View {
        HStack(spacing: 6) {
            Spinner(lineWidth: 1.5, duration: 0.7)
                .frame(width: 10, height: 10)
            Text("Agent resolving conflicts…")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func reportRow(_ report: BulkConflictResolveReport) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: reportIcon(for: report))
                .foregroundColor(reportColor(for: report))
                .font(.system(size: 10))
                .padding(.top, 1)
            Text(report.summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismissBulkReport) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .help(report.details.isEmpty ? report.summary : report.details)
    }

    private func reportIcon(for report: BulkConflictResolveReport) -> String {
        if !report.success { return "exclamationmark.triangle.fill" }
        return report.remainingConflicts == 0
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private func reportColor(for report: BulkConflictResolveReport) -> Color {
        if !report.success { return .red }
        return report.remainingConflicts == 0 ? .green : .orange
    }

    @ViewBuilder
    private func row(for file: ChangedFile) -> some View {
        rowContent(for: file)
            .dragOut { dragPayload?(file) }
    }

    @ViewBuilder
    private func rowContent(for file: ChangedFile) -> some View {
        switch file.conflict {
        case .bothDeleted:
            bothDeletedRow(file)
        case .deletedByUs, .deletedByThem:
            deleteSideRow(file)
        default:
            textConflictRow(for: file)
        }
    }

    private func textConflictRow(for file: ChangedFile) -> some View {
        Button(action: { onSelect(file) }) {
            HStack(spacing: 6) {
                Image(systemName: iconName(for: file.conflict))
                    .foregroundColor(iconColor(for: file.conflict))
                    .frame(width: 14)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)
                Spacer()
                Text(kindLabel(file.conflict))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            menuItems(for: file)
        }
    }

    private func bothDeletedRow(_ file: ChangedFile) -> some View {
        Button(action: { pendingBothDeletedConfirm = file }) {
            HStack(spacing: 6) {
                Image(systemName: "trash.fill")
                    .foregroundColor(.red)
                    .frame(width: 14)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)
                Spacer()
                Text("both deleted")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .confirmationDialog(
            "Both sides deleted this file. Stage the deletion?",
            isPresented: Binding(
                get: { pendingBothDeletedConfirm?.id == file.id },
                set: { if !$0 { pendingBothDeletedConfirm = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep deleted", role: .destructive) {
                onKeepDeleted(file)
                pendingBothDeletedConfirm = nil
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func deleteSideRow(_ file: ChangedFile) -> some View {
        let isOursDeleted = file.conflict == .deletedByUs
        return HStack(spacing: 6) {
            Button(action: { onSelect(file) }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash.fill")
                        .foregroundColor(.orange)
                        .frame(width: 14)
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(isOursDeleted ? "Keep theirs" : "Keep ours") {
                if isOursDeleted { onUseTheirs(file) } else { onUseOurs(file) }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            Button("Keep deleted") { onKeepDeleted(file) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.red)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contextMenu {
            if isOursDeleted {
                Button("Keep theirs") { onUseTheirs(file) }
            } else {
                Button("Keep ours") { onUseOurs(file) }
            }
            Button("Keep deleted") { onKeepDeleted(file) }
            Divider()
            Button("Mark resolved") { onMarkResolved(file) }
        }
    }

    /// Context menu for `textConflictRow` only. Delete-side and bothDeleted
    /// rows render their own dedicated rows + menus and never reach here.
    @ViewBuilder
    private func menuItems(for file: ChangedFile) -> some View {
        switch file.conflict {
        case .bothModified, .bothAdded:
            Button("Use ours") { onUseOurs(file) }
            Button("Use theirs") { onUseTheirs(file) }
        case .addedByUs:
            Button("Keep ours") { onUseOurs(file) }
        case .addedByThem:
            Button("Keep theirs") { onUseTheirs(file) }
        case .deletedByUs, .deletedByThem, .bothDeleted, nil:
            EmptyView()
        }
        Divider()
        Button("Mark resolved") { onMarkResolved(file) }
    }

    private func iconName(for kind: ConflictKind?) -> String {
        switch kind {
        case .bothModified, .bothAdded, .bothDeleted, nil:
            return "exclamationmark.triangle.fill"
        case .deletedByUs, .deletedByThem:
            return "trash.fill"
        case .addedByUs, .addedByThem:
            return "plus.circle.fill"
        }
    }

    private func iconColor(for kind: ConflictKind?) -> Color {
        switch kind {
        case .bothDeleted: return .red
        default:           return .orange
        }
    }

    private func kindLabel(_ kind: ConflictKind?) -> String {
        switch kind {
        case .bothModified:  return "both modified"
        case .bothAdded:     return "both added"
        case .bothDeleted:   return "both deleted"
        case .addedByUs:     return "added by us"
        case .addedByThem:   return "added by them"
        case .deletedByUs:   return "deleted by us"
        case .deletedByThem: return "deleted by them"
        case nil:            return ""
        }
    }
}
