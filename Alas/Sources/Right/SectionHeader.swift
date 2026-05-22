import SwiftUI

/// Top-level collapsible section header used inside the Changes tab
/// ("Working tree", "Commits"). The whole row is the click target.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    let expanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Icon(name: expanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(theme.color("fg-muted"))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(theme.color("bg-4"))
                        .clipShape(Capsule())
                        .foregroundColor(theme.color("fg-muted"))
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int?, expanded: Bool, onToggle: @escaping () -> Void) {
        self.init(title: title, count: count, expanded: expanded, onToggle: onToggle, trailing: { EmptyView() })
    }
}
