import SwiftUI

struct StageChip: View {
    let staged: Bool
    let action: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(staged ? theme.color("add").opacity(0.18) : theme.color("bg-3"))
                    .frame(width: 14, height: 14)
                Icon(
                    name: staged ? "check" : "plus",
                    size: 9,
                    color: staged ? theme.color("add") : theme.color("fg-dim")
                )
            }
        }
        .buttonStyle(.plain)
        .help(staged ? "Unstage" : "Stage")
    }
}
