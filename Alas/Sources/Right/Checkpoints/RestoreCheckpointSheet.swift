import Observation
import SwiftUI

enum CheckpointRestoreErrorPresentation {
    static func message(_ error: Error) -> String {
        guard let restoreError = error as? CheckpointRestoreError else {
            return error.localizedDescription
        }
        switch restoreError {
        case let .blocked(blocker):
            return blocker.description
        case .stalePreview:
            return "Refresh the restore preview before trying again."
        case .emptySelection:
            return "Select at least one file group to restore."
        case let .missingPreviewGroup(id):
            return "The restore preview no longer contains group \(id.uuidString). Refresh the preview."
        case let .missingCurrentPath(path):
            return "The current worktree state for \(path) could not be read. Refresh the preview."
        case let .missingDesiredPath(path):
            return "The checkpoint state for \(path) could not be read."
        case .invalidGitOutput:
            return "Git returned output Alas could not parse."
        case .invalidJournal:
            return "The interrupted restore journal is invalid."
        case .restoreFailedButRecovered:
            return "Restore failed and the pre-restore state was recovered."
        case let .recoveryRequired(operationID, paths, phase):
            return "Restore interrupted in \(CheckpointRecoveryPresentation.phase(phase)) for \(paths.count) paths. Recover operation \(CheckpointRecoveryPresentation.operationSuffix(operationID)) before continuing."
        }
    }
}

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

struct RestoreCheckpointSheet: View {
    @Bindable var rps: RightPaneState
    let preview: CheckpointRestorePreview

    @State private var model: RestoreCheckpointSheetModel
    @Environment(\.dismiss) private var dismiss

    init(rps: RightPaneState, preview: CheckpointRestorePreview) {
        self.rps = rps
        self.preview = preview
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
            if let error = rps.lastCheckpointError {
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
                Task { @MainActor in
                    await rps.previewCheckpointRestore(id: preview.checkpointID, selectedGroupIDs: model.selectedGroupIDs)
                }
            }
            .disabled(rps.checkpointOperationInFlight != nil)
            Button("Cancel") {
                rps.checkpointRestorePreview = nil
                dismiss()
            }
            Button("Restore Selected Files", role: .destructive) {
                let selected = model.selectedGroupIDs
                Task { @MainActor in
                    await rps.restoreCheckpoint(preview: preview, selectedGroupIDs: selected)
                    if rps.checkpointRestorePreview == nil {
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!RestoreCheckpointSheetModel.canRestore(
                preview: preview,
                selectedGroupIDs: model.selectedGroupIDs,
                inFlight: rps.checkpointOperationInFlight != nil
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
