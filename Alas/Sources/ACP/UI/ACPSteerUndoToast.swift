import SwiftUI

/// Non-blocking 5-second toast that appears at the bottom of the chat
/// pane after a steer that discarded queued items. Tapping Undo
/// re-prepends the snapshot.
struct ACPSteerUndoToast: View {
    let discardedCount: Int
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @State private var visible: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
            Text("Discarded \(discardedCount) queued message\(discardedCount == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg"))
            Button("Undo", action: {
                onUndo()
                visible = false
            })
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.color("accent"))
            Button {
                visible = false
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.color("line"), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: visible)
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            visible = false
            onDismiss()
        }
    }
}
