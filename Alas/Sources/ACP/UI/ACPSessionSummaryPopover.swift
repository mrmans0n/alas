import Accessibility
import SwiftUI

struct ACPSessionSummaryPopover: View {
    @ObservedObject var coordinator: SessionSummaryCoordinator
    let session: ACPSession
    let presentation: ACPSessionSummaryPresentation
    @Binding var isPresented: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(theme.color("line"))
            VStack(alignment: .leading, spacing: 12) {
                Text("Generated locally. Review before acting.")
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-faint"))

                if presentation.showsRecentContextLabel {
                    Text("Summarizes recent context.")
                        .font(.caption)
                        .foregroundStyle(theme.color("fg-muted"))
                }

                ScrollView {
                    phaseContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
            }
            .padding(12)
        }
        .frame(width: 320)
        .background(theme.color("bg-1"))
        .onChange(of: presentation.accessibilityValue) { _, value in
            AccessibilityNotification.Announcement("Session summary: \(value)").post()
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(theme.color("accent"))
                .accessibilityHidden(true)
            Text("Session summary")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))
                .accessibilityHeading(.h2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-2").opacity(0.4))
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch coordinator.phase {
        case .idle:
            Text("Ready to summarize.")
                .font(.callout)
                .foregroundStyle(theme.color("fg-muted"))
        case .loading:
            HStack(spacing: 8) {
                if reduceMotion {
                    Image(systemName: "hourglass")
                        .accessibilityHidden(true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text("Summarizing session…")
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
        case .result:
            summarySections
            refreshButton(title: "Refresh")
        case .failed(let message, _):
            summarySections
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.color("del"))
                .textSelection(.enabled)
            refreshButton(title: "Retry")
        }
    }

    private var summarySections: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(presentation.sections) { section in
                ACPSessionSummarySection(section: section)
            }
        }
    }

    private func refreshButton(title: String) -> some View {
        Button(title) {
            Task { await coordinator.refresh(session) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct ACPSessionSummarySection: View {
    let section: ACPSessionSummaryPresentation.SectionDescriptor
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.color("fg-muted"))
                .accessibilityHeading(.h3)
            Text(text)
                .font(.callout)
                .foregroundStyle(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        switch section.kind {
        case .completed, .blockers:
            section.items.map { "• \($0)" }.joined(separator: "\n")
        case .goal, .nextAction:
            section.items.joined(separator: "\n")
        }
    }
}
