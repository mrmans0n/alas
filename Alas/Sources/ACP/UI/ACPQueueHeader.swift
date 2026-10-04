import SwiftUI

/// Thin header that sits above the "Up next" queue rows whenever at least
/// one pending item exists. Shows the count on the left and a "Clear"
/// text button on the right.
struct ACPQueueHeader: View {
    let count: Int
    var canClear = true
    let onClear: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("Up next · \(count) queued")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("fg-faint"))
            Spacer()
            if canClear {
                Button(action: onClear) {
                    Text("Clear")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                }
                .buttonStyle(.plain)
                .help("Remove pending prompts; background work notifications are retained")
            }
        }
        .padding(.horizontal, 4)
    }
}
