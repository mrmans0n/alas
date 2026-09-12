import Observation
import SwiftUI

@Observable
final class CreateCheckpointSheetModel {
    private var storedLabel = ""

    var label: String {
        get { storedLabel }
        set { storedLabel = String(newValue.prefix(120)) }
    }

    var canSubmit: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var unsavedBuffersMessage: String { "Unsaved editor buffers are not captured." }

    static func exclusionReason(_ reason: CheckpointExclusionReason) -> String {
        switch reason {
        case .ignoredByPolicy: "ignored by policy"
        case .likelySecret: "likely secret"
        case .tooLarge: "too large"
        case .specialFile: "special file"
        case .unsafePath: "unsafe path"
        case .internalRestoreDirectory: "internal restore directory"
        }
    }

    static func exclusionsText(_ exclusions: [CheckpointExclusion]) -> String {
        exclusions.map { "\($0.relativePath) — \(exclusionReason($0.reason))" }.joined(separator: "\n")
    }
}

struct CreateCheckpointSheet: View {
    @Bindable var rps: RightPaneState
    @State private var model = CreateCheckpointSheetModel()
    @State private var capturedManifest: WorktreeCheckpointManifest?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create checkpoint").font(.headline)
            if let capturedManifest {
                Text("Checkpoint saved: \(capturedManifest.label)")
                Text("\(capturedManifest.paths.count) files · \(CheckpointPresentation.bytes(capturedManifest.byteCount))")
                    .foregroundStyle(.secondary)
                exclusions(capturedManifest.exclusions)
            } else {
                TextField("Checkpoint name", text: $model.label)
                    .accessibilityIdentifier("checkpoint-label")
                Text("This captures the Git index and on-disk files. \(model.unsavedBuffersMessage)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error = rps.lastCheckpointError {
                    Text(error).foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(capturedManifest == nil ? "Create checkpoint" : "Done") {
                    if capturedManifest != nil { dismiss() } else { create() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(capturedManifest == nil && (!model.canSubmit || rps.checkpointMutationsDisabled))
                .accessibilityIdentifier("create-checkpoint")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private func exclusions(_ exclusions: [CheckpointExclusion]) -> some View {
        if !exclusions.isEmpty {
            DisclosureGroup("Excluded files (\(exclusions.count))") {
                ForEach(exclusions, id: \.relativePath) { exclusion in
                    Text("\(exclusion.relativePath) — \(CreateCheckpointSheetModel.exclusionReason(exclusion.reason))")
                }
            }
            .font(.callout)
        }
    }

    private func create() {
        let label = model.label.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            capturedManifest = await rps.createCheckpoint(label: label)
        }
    }
}
