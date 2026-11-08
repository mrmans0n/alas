import SwiftUI

/// Bar below the merge-conflict toolbar that explains the current hunk with
/// the on-device model. Explanations run automatically as conflicts become
/// current; the bar shows progress, the result, or a retry affordance.
/// Collapsing keeps a one-line summary and persists while the tab is open.
struct MergeConflictAnnotationStrip: View {
    @Environment(\.designScale) private var scale
    enum Status: Equatable {
        case explaining
        case explained(MergeConflictExplanation)
        case failed
    }

    let status: Status
    /// Identifies the hunk, e.g. "Conflict 2 of 5, lines 40–52".
    let citation: String
    let localLabel: String
    let remoteLabel: String
    let onRetry: () -> Void
    @Binding var isExpanded: Bool

    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            HStack(alignment: .firstTextBaseline, spacing: scale.space[2]) {
                statusIcon
                    .frame(width: 14, height: 14)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                Text(citation)
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .fixedSize()
                headline
                    .frame(maxWidth: .infinity, alignment: .leading)
                if case .explained = status {
                    Text("On-device · advisory")
                        .font(scale.caption.font(weight: .regular))
                        .foregroundColor(theme.color("fg-faint"))
                        .fixedSize()
                        .help("Generated on this Mac. It may be wrong and changes nothing in the file.")
                    Button(action: { isExpanded.toggle() }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(scale.glyphFont)
                            .foregroundColor(theme.color("fg-dim"))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Show less" : "Show what each side intends")
                }
            }
            if case .explained(let explanation) = status, isExpanded {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                    intentRow(
                        side: "LOCAL",
                        label: localLabel,
                        tint: Color(nsColor: MergePalette(theme: theme).local),
                        text: explanation.localIntent
                    )
                    intentRow(
                        side: "REMOTE",
                        label: remoteLabel,
                        tint: Color(nsColor: MergePalette(theme: theme).remote),
                        text: explanation.remoteIntent
                    )
                }
                .padding(.leading, 22) // design-literal: aligns under the fixed-width marker column
            }
        }
        .padding(.horizontal, scale.space[3])
        .padding(.vertical, scale.space[2])
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"))
        .overlay(Divider(), alignment: .bottom)
        .animation(.easeOut(duration: 0.15), value: status)
        .animation(.easeOut(duration: 0.15), value: isExpanded)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .explaining:
            Spinner(lineWidth: 1.5, duration: 0.7)
        case .explained:
            Image(systemName: "sparkles")
                .font(scale.metaFont)
                .foregroundColor(theme.color("accent"))
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
        }
    }

    @ViewBuilder
    private var headline: some View {
        switch status {
        case .explaining:
            Text("Reading both sides…")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
        case .explained(let explanation):
            Text(explanation.cause)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg"))
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.tail)
                .textSelection(.enabled)
        case .failed:
            HStack(spacing: scale.space[2]) {
                Text("Couldn't explain this conflict.")
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                Button("Retry", action: onRetry)
                    .buttonStyle(.link)
                    .font(scale.metaFont)
            }
        }
    }

    private func intentRow(side: String, label: String, tint: Color, text: String) -> some View {
        GridRow {
            HStack(spacing: scale.space[1]) {
                RoundedRectangle(cornerRadius: scale.radius.small)
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(side)
                    .font(scale.caption.font(weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(theme.color("fg-muted"))
                if !label.isEmpty {
                    Text(label)
                        .font(scale.meta.font(design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .leading)
                }
            }
            Text(text)
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
