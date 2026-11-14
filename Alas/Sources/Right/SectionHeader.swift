import SwiftUI

enum SectionHeaderRole: Equatable {
    enum IconKind: Equatable {
        case standard(String)
        case stack
    }

    case workingTree
    case checkpoints
    case commits
    case stack
    case stashes
    case reviews

    var iconKind: IconKind {
        switch self {
        case .workingTree: return .standard("diff")
        case .checkpoints: return .standard("clock.arrow.circlepath")
        case .commits: return .standard("commit")
        case .stack: return .stack
        case .stashes: return .standard("archivebox")
        case .reviews: return .standard("text.bubble")
        }
    }

    static func accessibilityValue(expanded: Bool) -> String {
        expanded ? "Expanded" : "Collapsed"
    }
}

struct SectionHeaderIcon: View {
    let role: SectionHeaderRole
    let size: CGFloat
    let color: Color

    @ViewBuilder
    var body: some View {
        switch role.iconKind {
        case let .standard(name):
            Icon(name: name, size: size, color: color)
        case .stack:
            GGStackIcon(size: size, color: color)
        }
    }
}

/// Top-level collapsible section header used inside the Changes tab
/// ("Working tree", "Commits"). The whole row is the click target.
struct SectionHeader<Trailing: View>: View {
    let role: SectionHeaderRole
    let title: String
    let count: Int?
    let expanded: Bool
    let onToggle: () -> Void
    var stats: (add: Int, del: Int)? = nil
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    // This is a stable section-identity icon, not an expansion
                    // indicator. Expansion state is conveyed by visible content
                    // and the button's accessibility value.
                    SectionHeaderIcon(
                        role: role,
                        size: scale.caption.size,
                        color: theme.color("fg-faint")
                    )
                        .frame(width: scale.space[4], height: scale.space[4])
                        .accessibilityHidden(true)
                    Text(title.uppercased())
                        .font(scale.caption.font(weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(theme.color("fg-muted"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let count {
                        Text("\(count)")
                            .font(scale.caption.font(weight: .semibold))
                            .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[0] / 2)
                            .background(theme.color("seg-pill-bg"))
                            .clipShape(Capsule())
                            .foregroundColor(theme.color("fg-muted"))
                    }
                    Spacer(minLength: 8)
                    if let stats, shouldShowChangeSummary(additions: stats.add, deletions: stats.del) {
                        HStack(spacing: 6) {
                            Text("+" + WorktreeRowPresentation.compactCount(stats.add)).foregroundColor(theme.color("add"))
                            Text("−" + WorktreeRowPresentation.compactCount(stats.del)).foregroundColor(theme.color("del"))
                        }
                        .font(scale.caption.font(weight: .semibold, design: .monospaced))
                        .help("\(stats.add) lines added, \(stats.del) lines deleted")
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(SectionHeaderRole.accessibilityValue(expanded: expanded))
            trailing()
        }
        .paneBand(fill: theme.color("section-head-bg"))
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(
        role: SectionHeaderRole,
        title: String,
        count: Int?,
        expanded: Bool,
        stats: (add: Int, del: Int)? = nil,
        onToggle: @escaping () -> Void
    ) {
        self.init(
            role: role,
            title: title,
            count: count,
            expanded: expanded,
            onToggle: onToggle,
            stats: stats,
            trailing: { EmptyView() }
        )
    }
}
