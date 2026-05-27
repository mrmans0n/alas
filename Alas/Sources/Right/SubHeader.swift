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

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Icon(
                    name: expanded ? "chev-down" : "chev-right",
                    size: 9,
                    color: staged ? theme.color("staged-chev") : theme.color("fg-faint")
                )
                .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.color("fg-muted"))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("seg-pill-bg"))
                    .clipShape(Capsule())
                    .foregroundColor(theme.color("fg-muted"))
                Spacer(minLength: 8)
                if let stats, shouldShowChangeSummary(additions: stats.add, deletions: stats.del) {
                    HStack(spacing: 6) {
                        Text("+\(stats.add)").foregroundColor(theme.color("add"))
                        Text("−\(stats.del)").foregroundColor(theme.color("del"))
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                }
                if let trailing { trailing }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(theme.color("section-head-bg"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
