import SwiftUI

struct ACPSessionForkPresentation: Equatable {
    let title: String
    let notice: String?

    init(sourceAgentName: String, mechanism: ACPSessionForkMechanism) {
        switch mechanism {
        case .nativeACP:
            title = "Forked from \(sourceAgentName)"
            notice = nil
        case .transcriptTransfer:
            title = "Conversation imported from \(sourceAgentName)"
            notice = "Provider-specific tool state, hidden context, and attachments were not transferred. This chat shares the source chat’s current worktree."
        }
    }
}

struct ACPSessionForkDivider: View {
    let presentation: ACPSessionForkPresentation
    let onOpenSource: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Rectangle().fill(theme.color("line")).frame(height: 1)
                Button(presentation.title, action: onOpenSource)
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.color("accent"))
                    .help("Open source chat")
                Rectangle().fill(theme.color("line")).frame(height: 1)
            }
            if let notice = presentation.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
