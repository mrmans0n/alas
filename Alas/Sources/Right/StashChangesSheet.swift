import SwiftUI

struct StashChangesSheet: View {
    let onStash: (String, Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var message = ""
    @State private var includeUntracked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes")
                .font(scale.titleFont)
                .foregroundColor(theme.color("fg"))
            Text("Move current working-tree changes into a git stash.")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-muted"))
            AlasField(
                text: $message,
                placeholder: "Optional message",
                focusOnAppear: true,
                onSubmit: { onStash(message, includeUntracked) }
            )
            Toggle("Include untracked files", isOn: $includeUntracked)
                .toggleStyle(.checkbox)
                .font(scale.metaFont)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Stash Changes") {
                    onStash(message, includeUntracked)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(scale.space[4])
        .frame(width: 360)
        .background(theme.color("bg-2"))
    }
}
