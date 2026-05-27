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
        if lower.contains("disconnected") { return "bolt.slash" }
        return "info.circle"
    }
}
