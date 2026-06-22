import SwiftUI

struct ParkChangesSheet: View {
    let onPark: (String, Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var message = ""
    @State private var includeUntracked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Park Changes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Move current working-tree changes into a git stash.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
            AlasField(
                text: $message,
                placeholder: "Optional message",
                focusOnAppear: true,
                onSubmit: { onPark(message, includeUntracked) }
            )
            Toggle("Include untracked files", isOn: $includeUntracked)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Park Changes") {
                    onPark(message, includeUntracked)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(theme.color("bg-2"))
    }
}
