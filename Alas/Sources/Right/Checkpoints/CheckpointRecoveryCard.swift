import SwiftUI

enum CheckpointRecoveryPresentation {
    static func phase(_ phase: CheckpointRestoreJournal.Phase) -> String {
        switch phase {
        case .prepared: "Prepared"
        case .applyingFiles: "Applying files"
        case .installingIndex: "Installing index"
        case .verifying: "Verifying"
        case .rollingBack: "Rolling back"
        case .completed: "Completed"
        case .recovered: "Recovered"
        }
    }

    static func operationSuffix(_ id: UUID) -> String {
        String(id.uuidString.suffix(8)).lowercased()
    }

    static func affectedPathsSummary(_ paths: [String]) -> String {
        switch paths.count {
        case 0:
            "No paths recorded"
        case 1:
            paths[0]
        default:
            "\(paths.count) paths"
        }
    }

    static func affectedPathsText(_ paths: [String]) -> String {
        paths.sorted().joined(separator: "\n")
    }

    static let recoverButtonTitle = "Recover pre-restore state"
}

struct CheckpointRecoveryCard: View {
    let journal: CheckpointRestoreJournal
    let inFlight: Bool
    let error: String?
    let status: String?
    let onRecover: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Interrupted restore \(CheckpointRecoveryPresentation.operationSuffix(journal.id))")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(CheckpointRecoveryPresentation.phase(journal.phase))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
            }
            Text("Recover the pre-restore state before creating, deleting, or restoring another checkpoint.")
                .font(.system(size: 10))
                .foregroundColor(theme.color("fg-muted"))
            DisclosureGroup(CheckpointRecoveryPresentation.affectedPathsSummary(journal.selectedPaths)) {
                Text(CheckpointRecoveryPresentation.affectedPathsText(journal.selectedPaths))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.color("fg-muted"))
                    .textSelection(.enabled)
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
