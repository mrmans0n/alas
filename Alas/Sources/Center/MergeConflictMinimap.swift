import SwiftUI

struct MergeConflictMinimap: View {
    @Environment(\.designScale) private var scale
    let conflictCount: Int          // unresolved
    let resolvedCount: Int          // initialConflictCount - conflictCount
    let currentConflictIndex: Int?
    let onJump: (Int) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: scale.space[0]) {
            // Resolved ticks (green, not clickable)
            ForEach(0..<resolvedCount, id: \.self) { _ in
                Rectangle()
                    .fill(theme.color("add"))
                    .opacity(0.65)
                    .frame(width: 6, height: 14)
                    .cornerRadius(1)
            }
            // Unresolved ticks (yellow, clickable to jump)
            ForEach(0..<conflictCount, id: \.self) { i in
                Button(action: { onJump(i) }) {
                    Rectangle()
                        .fill(tintFor(i))
                        .frame(width: 6, height: 14)
                        .cornerRadius(1)
                }
                .buttonStyle(.plain)
                .help("Conflict \(i + 1)")
            }
            Spacer()
        }
        .padding(.vertical, scale.space[2])
        .padding(.horizontal, scale.space[1])
        .background(theme.color("bg-1"))
        .overlay(Divider(), alignment: .leading)
    }

    private func tintFor(_ i: Int) -> Color {
        if i == currentConflictIndex {
            return theme.color("warn")
        }
        return theme.color("warn").opacity(0.55)
    }
}
