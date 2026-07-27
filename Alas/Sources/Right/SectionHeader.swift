import SwiftUI

enum SectionHeaderRole: Equatable {
    enum IconKind: Equatable {
        case standard(String)
        case stack
    }

    case workingTree
    case commits
    case stack
    case stashes

    var iconKind: IconKind {
        switch self {
        case .workingTree: return .standard("diff")
        case .commits: return .standard("commit")
        case .stack: return .stack
        case .stashes: return .standard("archivebox")
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

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                // This is a stable section-identity icon, not an expansion
                // indicator. Expansion state is conveyed by visible content
                // and the button's accessibility value.
                SectionHeaderIcon(
                    role: role,
                    size: 10,
                    color: theme.color("fg-faint")
                )
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.color("seg-pill-bg"))
                        .clipShape(Capsule())
                        .foregroundColor(theme.color("fg-muted"))
                }
                Spacer(minLength: 8)
                if let stats, shouldShowChangeSummary(additions: stats.add, deletions: stats.del) {
                    HStack(spacing: 6) {
                        Text("+\(stats.add)").foregroundColor(theme.color("add"))
                        Text("−\(stats.del)").foregroundColor(theme.color("del"))
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                }
                trailing()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(theme.color("section-head-bg"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(SectionHeaderRole.accessibilityValue(expanded: expanded))
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
