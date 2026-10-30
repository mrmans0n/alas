import SwiftUI

struct CheckpointRecoveryCard: View {
    /// Nil on a paired Mac, which knows only that a host's restore was interrupted.
    let journal: CheckpointRestoreJournal?
    let inFlight: Bool
    let error: String?
    let status: String?
    let onRecover: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(journal.map { "Interrupted restore \(CheckpointRecoveryPresentation.operationSuffix($0.id))" } ?? "Interrupted restore")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let journal {
                    Text(CheckpointRecoveryPresentation.phase(journal.phase))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.color("fg-muted"))
                }
            }
            Text("Recover the pre-restore state before creating, deleting, or restoring another checkpoint.")
                .font(.system(size: 10))
                .foregroundColor(theme.color("fg-muted"))
            if let journal {
                DisclosureGroup(CheckpointRecoveryPresentation.affectedPathsSummary(journal.selectedPaths)) {
                    Text(CheckpointRecoveryPresentation.affectedPathsText(journal.selectedPaths))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.color("fg-muted"))
                        .textSelection(.enabled)
                }
            }
            if let status {
                Text(status)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("add"))
            }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("del"))
            }
            HStack {
                Spacer()
                Button(CheckpointRecoveryPresentation.recoverButtonTitle) {
                    onRecover()
                }
                .disabled(inFlight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
