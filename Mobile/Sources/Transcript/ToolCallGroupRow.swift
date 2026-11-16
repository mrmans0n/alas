import AlasRemoteKit
import SwiftUI

/// The header of a folded run of thinking and tool calls, as the Mac's `ACPToolCallGroupHeaderRow`.
/// The header toggles; "Show N earlier" is its own button so VoiceOver reaches it. Members, when
/// expanded, are sibling rows below it.
struct ToolCallGroupRow: View {
    let summary: ACPToolCallGroupSummary
    let expanded: Bool
    let hiddenCount: Int
    let toggle: () -> Void
    let showAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: summary.iconSystemName).accessibilityHidden(true)
                    label.lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: summary.label))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if hiddenCount > 0 {
                Button("Show \(hiddenCount) earlier", action: showAll).font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var label: Text {
        guard let failure = summary.failureLabel else { return Text(verbatim: summary.labelBeforeFailure) }
        let before = summary.labelBeforeFailure + ACPToolCallGroupSummary.failureSeparator
        return Text("\(Text(verbatim: before))\(Text(verbatim: failure).foregroundStyle(.red))")
    }
}
