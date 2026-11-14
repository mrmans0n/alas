import SwiftUI

/// Lighter sub-section header used for "Staged" / "Changes" inside the
/// Working tree section.
struct SubHeader: View {
    let title: String
    let count: Int
    let expanded: Bool
    let onToggle: () -> Void
    var staged: Bool = false
    var stats: (add: Int, del: Int)? = nil
    var trailing: AnyView? = nil

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Icon(
                    name: expanded ? "chev-down" : "chev-right",
                    size: scale.glyph.size,
                    color: staged ? theme.color("staged-chev") : theme.color("fg-faint")
                )
                .frame(width: scale.space[3], height: scale.space[3])
                Text(title)
                    .font(scale.caption.font(weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.color("fg-muted"))
                Text("\(count)")
                    .font(scale.caption.font(weight: .semibold))
                    .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[0] / 2)
                    .background(theme.color("seg-pill-bg"))
                    .clipShape(Capsule())
                    .foregroundColor(theme.color("fg-muted"))
                Spacer(minLength: 8)
                if let stats, shouldShowChangeSummary(additions: stats.add, deletions: stats.del) {
                    HStack(spacing: 6) {
                        Text("+" + WorktreeRowPresentation.compactCount(stats.add)).foregroundColor(theme.color("add"))
                        Text("−" + WorktreeRowPresentation.compactCount(stats.del)).foregroundColor(theme.color("del"))
                    }
                    .font(scale.caption.font(weight: .semibold, design: .monospaced))
                    .help("\(stats.add) lines added, \(stats.del) lines deleted")
                }
                if let trailing { trailing }
            }
            .paneBand(fill: theme.color("section-head-bg"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(SectionHeaderRole.accessibilityValue(expanded: expanded))
    }
}
