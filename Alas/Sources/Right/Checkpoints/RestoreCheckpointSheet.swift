import Observation
import SwiftUI

@Observable
final class RestoreCheckpointSheetModel {
    var selectedGroupIDs: Set<UUID>

    init(preview: CheckpointRestorePreview) {
        selectedGroupIDs = preview.selectedGroupIDs
    }

    func isSelected(_ group: CheckpointRestoreGroup) -> Bool {
        selectedGroupIDs.contains(group.id)
    }

    func setSelected(_ selected: Bool, group: CheckpointRestoreGroup) {
        if selected {
            selectedGroupIDs.insert(group.id)
        } else {
            selectedGroupIDs.remove(group.id)
        }
    }

    func toggle(_ group: CheckpointRestoreGroup) {
        setSelected(!isSelected(group), group: group)
    }

    func selectAll(_ preview: CheckpointRestorePreview) {
        selectedGroupIDs = Set(preview.groups.map(\.id))
    }

    static func selectedPathCount(preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>) -> Int {
        Set(preview.groups
            .filter { selectedGroupIDs.contains($0.id) }
            .flatMap(\.memberPaths))
            .count
    }

    static func canRestore(preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>, inFlight: Bool) -> Bool {
        !inFlight && preview.blocker == nil && !selectedGroupIDs.isEmpty
    }

    static func confirmationSummary(preview: CheckpointRestorePreview, selectedGroupIDs: Set<UUID>) -> String {
        let groupCount = selectedGroupIDs.count
        let pathCount = selectedPathCount(preview: preview, selectedGroupIDs: selectedGroupIDs)
        let groupWord = groupCount == 1 ? "file group" : "file groups"
        let pathWord = pathCount == 1 ? "path" : "paths"
        return "\(groupCount) \(groupWord), \(pathCount) physical \(pathWord)"
    }

    static func title(for group: CheckpointRestoreGroup) -> String {
        group.renameSource.map { "\($0) → \(group.primaryPath)" } ?? group.primaryPath
    }

    static func effectLines(for group: CheckpointRestoreGroup) -> [String] {
        group.effects.map { "\($0.relativePath) · \($0.description)" }
    }

    static func blockerMessage(_ blocker: CheckpointRestoreBlocker?) -> String? {
        blocker?.description
    }
}

/// Restores a checkpoint's selected groups: this Mac's worktree through
/// `RightPaneState`, a paired host's through closures.
struct RestoreCheckpointSheet: View {
    let preview: CheckpointRestorePreview
    /// Read in `body`, so a `RightPaneState` source stays observed.
    private let error: @MainActor () -> String?
    private let inFlight: @MainActor () -> Bool
    private let refresh: @MainActor (Set<UUID>) async -> Void
    /// True once restored, to dismiss.
    private let restore: @MainActor (Set<UUID>) async -> Bool
    private let cancel: @MainActor () -> Void

    @State private var model: RestoreCheckpointSheetModel
    @Environment(\.dismiss) private var dismiss

    init(
        preview: CheckpointRestorePreview, error: String?, inFlight: Bool,
        refresh: @escaping @MainActor (Set<UUID>) async -> Void,
        restore: @escaping @MainActor (Set<UUID>) async -> Bool,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.preview = preview
        self.error = { error }
        self.inFlight = { inFlight }
        self.refresh = refresh
        self.restore = restore
        self.cancel = cancel
        _model = State(initialValue: RestoreCheckpointSheetModel(preview: preview))
    }

    init(rps: RightPaneState, preview: CheckpointRestorePreview) {
        self.preview = preview
        error = { rps.lastCheckpointError }
        inFlight = { rps.checkpointOperationInFlight != nil }
        refresh = { await rps.previewCheckpointRestore(id: preview.checkpointID, selectedGroupIDs: $0) }
        restore = {
            await rps.restoreCheckpoint(preview: preview, selectedGroupIDs: $0)
            return rps.checkpointRestorePreview == nil
        }
        cancel = { rps.checkpointRestorePreview = nil }
        _model = State(initialValue: RestoreCheckpointSheetModel(preview: preview))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let blocker = RestoreCheckpointSheetModel.blockerMessage(preview.blocker) {
                Text(blocker)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("checkpoint-restore-blocker")
            }
            if let error = error() {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("checkpoint-restore-error")
            }
            List {
                ForEach(preview.groups) { group in
                    CheckpointRestoreGroupRow(
                        group: group,
                        selected: model.isSelected(group),
                        onToggle: { model.toggle(group) }
                    )
                    .tag(group.id)
                }
            }
            .frame(minHeight: 220)
            footer
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Restore checkpoint").font(.headline)
            Text(preview.checkpointLabel)
                .font(.subheadline)
            Text(preview.scopeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Both Git index and working-tree file state will be restored for selected paths. Current state is captured as a recovery checkpoint first.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(RestoreCheckpointSheetModel.confirmationSummary(
                preview: preview,
                selectedGroupIDs: model.selectedGroupIDs
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh Preview") {
                let selected = model.selectedGroupIDs
                Task { @MainActor in
                    await refresh(selected)
                }
            }
            .disabled(inFlight())
            Button("Cancel") {
                cancel()
                dismiss()
            }
            Button("Restore Selected Files", role: .destructive) {
                let selected = model.selectedGroupIDs
                Task { @MainActor in
                    if await restore(selected) {
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!RestoreCheckpointSheetModel.canRestore(
                preview: preview,
                selectedGroupIDs: model.selectedGroupIDs,
                inFlight: inFlight()
            ))
            .accessibilityIdentifier("checkpoint-restore-selected")
        }
    }
}

private struct CheckpointRestoreGroupRow: View {
    let group: CheckpointRestoreGroup
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(RestoreCheckpointSheetModel.title(for: group))
                        .font(.system(size: 12, weight: .medium))
                    ForEach(RestoreCheckpointSheetModel.effectLines(for: group), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RestoreCheckpointSheetModel.title(for: group))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}
