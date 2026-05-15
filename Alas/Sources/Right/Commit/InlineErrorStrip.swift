import SwiftUI

struct InlineErrorStrip: View {
    let message: String
    let onDismiss: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 8) {
            Icon(name: "alert", size: 11, color: theme.color("del"))
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(theme.color("fg"))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Icon(name: "x", size: 10, color: theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(theme.color("del").opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.color("del").opacity(0.30), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
    }
}
