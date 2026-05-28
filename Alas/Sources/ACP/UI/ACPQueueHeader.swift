import SwiftUI

/// Thin header that sits above the pending bubbles when the queue has
/// more than one item. Shows the count on the left and a "Clear queue"
/// text button on the right.
struct ACPQueueHeader: View {
    let count: Int
    let onClear: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("\(count) queued")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
            Button(action: onClear) {
                Text("Clear queue")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .buttonStyle(.plain)
            .help("Remove all pending items (a sending item is left alone)")
        }
        .padding(.horizontal, 4)
    }
}
