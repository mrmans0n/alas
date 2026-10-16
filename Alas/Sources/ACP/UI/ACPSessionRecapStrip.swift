import Accessibility
import SwiftUI

/// Recap row at the top of the composer pill. Shown for the automatic return
/// recap, collapsed to one line, and for the toolbar's Summarize Session
/// button, expanded. It gates itself so only the tab whose session the
/// coordinator is bound to renders it.
struct ACPSessionRecapStrip: View {
    @ObservedObject var coordinator: SessionSummaryCoordinator
    @ObservedObject var session: ACPSession

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The user's chevron choice; nil follows the request mode.
    @State private var expansionOverride: Bool?

    private var content: ACPSessionSummaryPresentation.CardContent {
        guard coordinator.boundSessionIncarnation == session.incarnation else { return .hidden }
        return ACPSessionSummaryPresentation.cardContent(cardMode: coordinator.cardMode, phase: coordinator.phase)
    }

    /// The user asked for a manual summary, so it opens expanded; a recap the
    /// app offered on its own stays one line until asked.
    private var isExpanded: Bool {
        expansionOverride ?? (coordinator.cardMode == .manual)
    }

    var body: some View {
        let content = content
        if content != .hidden {
            VStack(alignment: .leading, spacing: 6) {
                headerRow(content)
                if isExpanded, case .sections(let sections, let recentContext) = content {
                    details(sections, recentContext: recentContext)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("accent").opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.color("accent").opacity(0.22), lineWidth: 0.5)
            }
            .onChange(of: coordinator.cardMode) { _, _ in expansionOverride = nil }
            // `initial`: a strip can appear already filled from a cache.
            .onChange(of: content, initial: true) { _, value in
                guard let announcement = Self.announcement(for: value) else { return }
                AccessibilityNotification.Announcement(announcement).post()
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("acp-session-recap-strip")
        }
    }

    private func headerRow(_ content: ACPSessionSummaryPresentation.CardContent) -> some View {
        HStack(spacing: 6) {
            Label("Recap", systemImage: "arrow.counterclockwise")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            switch content {
            case .hidden:
                EmptyView()
            case .loading:
                loadingLabel
                Spacer(minLength: 0)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("del"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
                Spacer(minLength: 0)
                Button("Retry") {
                    Task { await coordinator.refresh(session, mode: .manual) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.color("accent"))
            case .sections(let sections, _):
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expansionOverride = !isExpanded }
                } label: {
                    HStack(spacing: 6) {
                        headline(sections)
                        Spacer(minLength: 0)
                        if !isExpanded { countChips(sections) }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse recap" : "Expand recap")
                if isExpanded {
                    iconButton("arrow.clockwise", help: "Refresh", label: "Refresh recap") {
                        Task { await coordinator.refresh(session, mode: .manual) }
                    }
                }
            }
            iconButton("xmark", help: "Dismiss", label: "Dismiss recap") {
                coordinator.dismissCard()
            }
        }
    }

    /// Collapsed: the next action (else the goal). Expanded: the goal, since
    /// the details below list the next action.
    @ViewBuilder
    private func headline(_ sections: [ACPSessionSummaryPresentation.SectionDescriptor]) -> some View {
        let line: (label: String, text: String)? = isExpanded
            ? ACPSessionSummaryPresentation.items(.goal, in: sections).first.map { ("Goal", $0) }
            : ACPSessionSummaryPresentation.headline(sections)
        if let line {
            (Text("\(line.label): ").foregroundColor(theme.color("fg-muted")) + Text(line.text).foregroundColor(theme.color("fg")))
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(line.text)
        }
    }

    @ViewBuilder
    private func countChips(_ sections: [ACPSessionSummaryPresentation.SectionDescriptor]) -> some View {
        let done = ACPSessionSummaryPresentation.items(.completed, in: sections).count
        let blockers = ACPSessionSummaryPresentation.items(.blockers, in: sections).count
        if done > 0 { countChip("\(done) done", color: theme.color("fg-muted")) }
        if blockers > 0 { countChip(blockers == 1 ? "1 blocker" : "\(blockers) blockers", color: theme.color("del")) }
    }

    private func countChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.75))
            .fixedSize()
    }

    private func details(
        _ sections: [ACPSessionSummaryPresentation.SectionDescriptor],
        recentContext: Bool
    ) -> some View {
        // Plain content while it fits, so short recaps stay compact; a
        // ScrollView would take the whole height cap.
        ViewThatFits(in: .vertical) {
            detailRows(sections, recentContext: recentContext)
            ScrollView { detailRows(sections, recentContext: recentContext) }
        }
        .frame(maxHeight: 160)
    }

    private func detailRows(
        _ sections: [ACPSessionSummaryPresentation.SectionDescriptor],
        recentContext: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if recentContext {
                Text("Summarizes recent context.")
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-muted"))
            }
            ForEach(Self.detailKinds, id: \.self) { kind in
                ForEach(Array(ACPSessionSummaryPresentation.items(kind, in: sections).enumerated()), id: \.offset) { _, item in
                    detailRow(kind, item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The goal sits in the expanded header line.
    private static let detailKinds: [ACPSessionSummaryPresentation.SectionDescriptor.Kind] = [
        .completed, .blockers, .nextAction,
    ]

    private func detailRow(_ kind: ACPSessionSummaryPresentation.SectionDescriptor.Kind, _ item: String) -> some View {
        let (symbol, color): (String, Color) = switch kind {
        case .completed: ("checkmark", theme.color("add"))
        case .blockers: ("exclamationmark", theme.color("del"))
        case .nextAction, .goal: ("arrow.right", theme.color("accent"))
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 12)
                .accessibilityHidden(true)
            Text(item)
                .font(.system(size: 11.5, weight: kind == .nextAction ? .semibold : .regular))
                .foregroundStyle(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.rawValue): \(item)")
    }

    private var loadingLabel: some View {
        HStack(spacing: 6) {
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
                .font(.system(size: 11.5))
        }
        .foregroundStyle(theme.color("fg-muted"))
        .accessibilityElement(children: .combine)
    }

    private func iconButton(_ systemName: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10))
                .foregroundStyle(theme.color("fg-faint"))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private static func announcement(for content: ACPSessionSummaryPresentation.CardContent) -> String? {
        switch content {
        case .hidden, .loading: nil
        case .sections: "Session recap ready"
        case .failed: "Session recap failed"
        }
    }
}
