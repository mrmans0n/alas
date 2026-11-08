import SwiftUI

struct InlineErrorStrip: View {
    let message: String
    let onDismiss: () -> Void
    @State private var expanded: Bool
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    init(message: String, onDismiss: @escaping () -> Void, initiallyExpanded: Bool = false) {
        self.message = message
        self.onDismiss = onDismiss
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Icon(name: "alert", size: 11, color: theme.color("del"))
                .padding(.top, scale.space[0])
            messageView
            Button(action: onDismiss) {
                Icon(name: "x", size: 10, color: theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
        .background(theme.color("del").opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.small)
                .stroke(theme.color("del").opacity(0.30), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            expanded = true
        }
        .help(expanded ? "Select and copy error text" : "Click to expand error")
        .padding(.horizontal, scale.space[3])
    }

    @ViewBuilder
    private var messageView: some View {
        if expanded {
            ScrollView(.vertical) {
                messageText
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, scale.space[0])
            }
            .frame(maxWidth: .infinity, maxHeight: 180, alignment: .leading)
        } else {
            messageText
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageText: some View {
        Text(message)
            .font(scale.meta.font(weight: .regular, design: .monospaced))
            .foregroundColor(theme.color("fg"))
            .textSelection(.enabled)
    }
}
