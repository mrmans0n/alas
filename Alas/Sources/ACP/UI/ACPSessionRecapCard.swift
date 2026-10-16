import Accessibility
import SwiftUI

/// Inline "Where you left off" card above the composer. Shown for the
/// automatic return recap and for the toolbar's Summarize Session button.
/// It gates itself so only the tab whose session the coordinator is bound to
/// renders it.
struct ACPSessionRecapCard: View {
    @ObservedObject var coordinator: SessionSummaryCoordinator
    @ObservedObject var session: ACPSession
    let maxWidth: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: ACPSessionSummaryPresentation.CardContent {
        guard coordinator.boundSessionIncarnation == session.incarnation else { return .hidden }
        return ACPSessionSummaryPresentation.cardContent(cardMode: coordinator.cardMode, phase: coordinator.phase)
    }

    var body: some View {
        let content = content
        if content != .hidden {
            card(content)
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, 20)
                // `initial`: a card can appear already filled from a cache.
                .onChange(of: content, initial: true) { _, value in
                    guard let announcement = Self.announcement(for: value) else { return }
                    AccessibilityNotification.Announcement(announcement).post()
                }
        }
    }

    private func card(_ content: ACPSessionSummaryPresentation.CardContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(content)
            switch content {
            case .hidden:
                EmptyView()
            case .loading:
                loadingRow
            case .sections(let sections, let recentContext):
                if recentContext {
                    Text("Summarizes recent context.")
                        .font(.caption)
                        .foregroundStyle(theme.color("fg-muted"))
                }
                // Plain content while it fits, so short recaps stay compact;
                // a ScrollView would take the whole height cap.
                ViewThatFits(in: .vertical) {
                    sectionsStack(sections)
                    ScrollView { sectionsStack(sections) }
                }
                .frame(maxHeight: 220)
            case .failed(let message):
                HStack(spacing: 8) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("del"))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        Task { await coordinator.refresh(session, mode: .manual) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.color("accent"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Accent tint over an opaque base: the card floats above the transcript.
        .background(
            theme.color("accent").opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .background(theme.color("bg-1"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.color("accent").opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp-session-recap-card")
    }

    private func sectionsStack(_ sections: [ACPSessionSummaryPresentation.SectionDescriptor]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections) { section in
                ACPSessionRecapSection(section: section)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(_ content: ACPSessionSummaryPresentation.CardContent) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 10))
                .foregroundStyle(theme.color("accent"))
                .accessibilityHidden(true)
            Text("Where you left off")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if Self.offersRefresh(content) {
                Button {
                    Task { await coordinator.refresh(session, mode: .manual) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                .accessibilityLabel("Refresh recap")
            }
            Button {
                coordinator.dismissCard()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss recap")
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
            } else {
                Spinner(lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text("Catching up…")
                .font(.system(size: 12))
        }
        .foregroundStyle(theme.color("fg-muted"))
        .accessibilityElement(children: .combine)
    }

    private static func offersRefresh(_ content: ACPSessionSummaryPresentation.CardContent) -> Bool {
        switch content {
        case .sections, .failed: true
        case .hidden, .loading: false
        }
    }

    private static func announcement(for content: ACPSessionSummaryPresentation.CardContent) -> String? {
        switch content {
        case .hidden, .loading: nil
        case .sections: "Session recap ready"
        case .failed: "Session recap failed"
        }
    }
}

private struct ACPSessionRecapSection: View {
    let section: ACPSessionSummaryPresentation.SectionDescriptor
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.color("fg-muted"))
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.system(size: 12))
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
