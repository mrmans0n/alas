import SwiftUI

/// Lighter sub-section header used for "Staged" / "Unstaged" inside the
/// Working tree section.
struct SubHeader: View {
    let title: String
    let count: Int
    let expanded: Bool
    let onToggle: () -> Void
    var trailing: AnyView? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Icon(name: expanded ? "chev-down" : "chev-right", size: 9, color: theme.color("fg-faint"))
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("bg-4"))
                    .clipShape(Capsule())
                    .foregroundColor(theme.color("fg-muted"))
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
