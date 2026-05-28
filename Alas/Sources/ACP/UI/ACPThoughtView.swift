import SwiftUI

/// Collapsed-by-default "Thinking…" row. Click to expand and read the raw
/// reasoning text. Visually anchored by a left vertical accent bar.
struct ACPThoughtView: View {
    @ObservedObject var buffer: StreamingText
    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                        Text(expanded ? "Hide thinking" : "Thinking…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Text(buffer.value)
                        .font(.system(size: 12, design: .default).italic())
                        .foregroundStyle(theme.color("fg-dim"))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
