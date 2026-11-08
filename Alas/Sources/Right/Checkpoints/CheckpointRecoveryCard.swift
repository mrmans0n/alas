import SwiftUI

struct CheckpointRecoveryCard: View {
    /// Nil on a paired Mac, which knows only that a host's restore was interrupted.
    let journal: CheckpointRestoreJournal?
    let inFlight: Bool
    let error: String?
    let status: String?
    let onRecover: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(journal.map { "Interrupted restore \(CheckpointRecoveryPresentation.operationSuffix($0.id))" } ?? "Interrupted restore")
                    .font(scale.title.font(weight: .semibold))
                Spacer()
                if let journal {
                    Text(CheckpointRecoveryPresentation.phase(journal.phase))
                        .font(scale.captionFont)
                        .foregroundColor(theme.color("fg-muted"))
                }
            }
            Text("Recover the pre-restore state before creating, deleting, or restoring another checkpoint.")
                .font(scale.caption.font(weight: .regular))
                .foregroundColor(theme.color("fg-muted"))
            if let journal {
                DisclosureGroup(CheckpointRecoveryPresentation.affectedPathsSummary(journal.selectedPaths)) {
                    Text(CheckpointRecoveryPresentation.affectedPathsText(journal.selectedPaths))
                        .font(scale.caption.font(weight: .regular))
                        .foregroundColor(theme.color("fg-muted"))
                        .textSelection(.enabled)
                }
            }
            if let status {
                Text(status)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundColor(theme.color("add"))
            }
            if let error {
                Text(error)
                    .font(scale.caption.font(weight: .regular))
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
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
    }
}
