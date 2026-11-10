import SwiftUI

/// On-device roll-up above the inbox list. It is read-only: each group's
/// sources are listed with their deterministic title, state, and attribution,
/// while acknowledging and opening stay on the ordinary rows below.
struct AttentionRollUpCard: View {
    let phase: AttentionRollUpPhase
    let now: Date
    let canSummarize: Bool
    let onSummarize: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(scale.glyph.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-dim"))
                    .accessibilityHidden(true)
                Text("Roll-up")
                    .font(scale.meta.font(weight: .semibold))
                Spacer()
                actions
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(scale.glyph.font(weight: .medium))
                        .foregroundStyle(theme.color("fg-dim"))
                }
                .buttonStyle(.plain)
                .help("Dismiss this roll-up")
                .accessibilityLabel("Dismiss roll-up")
            }
            content
        }
        .padding(scale.space[3])
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay { RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        switch phase {
        case .summarizing:
            Button("Cancel", action: onCancel).controlSize(.small)
        case .failed, .stale:
            Button("Summarize Again", action: onSummarize)
                .controlSize(.small)
                .disabled(!canSummarize)
        case .current:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .summarizing:
            HStack(spacing: 6) {
                Spinner().frame(width: 12, height: 12)
                note("Grouping the items below on-device…")
            }
        case .failed:
            note("Couldn't group these items. The full list below is unchanged.")
        case .stale:
            note("The inbox changed since this roll-up was drafted.")
        case let .current(rollUp):
            ForEach(Array(rollUp.groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.summary)
                        .font(scale.body.font)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rollUp.items(in: group), id: \.eventID) { item in
                        source(AttentionInboxRowPresentation(item: item, now: now))
                    }
                }
            }
            if let disclosure = rollUp.coverage.disclosure {
                Text(disclosure)
                    .font(scale.meta.font)
                    .foregroundStyle(theme.color("warn"))
            }
            note("On-device grouping. Each line lists the items it describes; state and actions are on the items below.")
        }
    }

    private func source(_ row: AttentionInboxRowPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: row.emphasizesAction ? "exclamationmark.circle" : "clock")
                .font(scale.glyph.font)
                .foregroundStyle(theme.color(row.emphasizesAction ? "warn" : "fg-dim"))
                .accessibilityHidden(true)
            Text("\(row.title) · \(row.attribution)")
                .font(scale.meta.font)
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(row.title)\n\(row.attribution)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Source: \(row.title), \(row.attribution)")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(scale.meta.font)
            .foregroundStyle(theme.color("fg-dim"))
            .fixedSize(horizontal: false, vertical: true)
    }
}
