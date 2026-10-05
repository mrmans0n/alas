import SwiftUI

/// A repo header's trailing count that becomes a "+" while the row is
/// hovered. Local and peer repo headers share it so they stay identical.
struct SidebarHeaderCountPlusButton: View {
    let count: Int
    let rowHovering: Bool
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme
    @State private var plusHovering = false

    var body: some View {
        ZStack {
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.color("fg-faint"))
                .monospacedDigit()
                .opacity(rowHovering ? 0 : 1)
                .allowsHitTesting(false)
            Button(action: action) {
                Icon(name: "plus", size: 11,
                     color: plusHovering ? theme.color("fg") : theme.color("fg-faint"))
                    .frame(width: 18, height: 18)
                    .background(plusHovering ? theme.color("bg-4") : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .onHover { plusHovering = $0 }
            .help(help)
            .opacity(rowHovering ? 1 : 0)
            .allowsHitTesting(rowHovering)
        }
        .frame(width: 18, height: 18)
    }
}
