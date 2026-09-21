import SwiftUI

/// Muted single-line aside (e.g. "Agent disconnected.", "Blocked write
/// outside worktree: …"). Dashed bordered tag for visual lightness.
struct ACPSystemNoticeView: View {
    let text: String
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundStyle(theme.color("fg-faint"))
            Text(text)
                .font(.system(size: 11.5).italic())
                .foregroundStyle(theme.color("fg-faint"))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(theme.color("bg-1").opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
    }

    /// Pick an icon based on the notice text. Interruption notices get
    /// a stop glyph; everything else stays on the generic info icon.
    private var iconName: String {
        let lower = text.lowercased()
        if lower.hasPrefix("interrupted") { return "stop.circle" }
        if lower.contains("reconnected") { return "checkmark.circle" }
        if lower.contains("disconnected") { return "bolt.slash" }
        return "info.circle"
    }
}

/// Transient floating card above the composer pill for a live ACP
/// `session.notices` update. Distinct from `ACPSystemNoticeView` above:
/// that one is a muted transcript row for persisted client-side asides,
/// this one is dismissible chrome for an agent-sent, never-persisted
/// out-of-band event. Each severity gets a distinct color/icon; an
/// unrecognized (including `_`-prefixed) severity falls back to the
/// `info` style per spec.
struct ACPSessionNoticeBanner: View {
    let notice: ACPSessionNotice
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(accentColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                if let description = notice.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.color("fg-muted"))
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accentColor.opacity(0.35), lineWidth: 0.75)
        )
        .padding(.bottom, 6)
    }

    private var accentColor: Color {
        notice.severity.behavesAsInfo ? theme.color("info")
            : (notice.severity == .warning ? theme.color("warn") : theme.color("del"))
    }

    private var iconName: String {
        if notice.severity.behavesAsInfo { return "info.circle" }
        return notice.severity == .warning ? "exclamationmark.triangle" : "exclamationmark.octagon"
    }
}
