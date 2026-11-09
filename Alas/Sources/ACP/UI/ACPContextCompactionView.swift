import SwiftUI

/// A non-interactive transcript marker for a context compaction lifecycle.
struct ACPContextCompactionView: View {
    @Environment(\.designScale) private var scale
    let compaction: ACPContextCompaction
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            HStack(spacing: scale.space[2]) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("accent"))
                    .frame(width: 18, height: 18)
                    .background(theme.color("bg-0").opacity(0.8), in: RoundedRectangle(cornerRadius: scale.radius.small))
                Text(compaction.label)
                    .font(scale.caption.font(weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.color("fg-faint"))
                Spacer(minLength: 6)
                status
            }

            if let details = compaction.details { Text(details)
                .font(scale.meta.font(design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
            }
            if let error = compaction.error, !error.isEmpty {
                Text(error)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("del"))
            }
        }
        .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-1").opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch compaction.status {
        case .inProgress:
            Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
        case .completed:
            Image(systemName: "checkmark")
                .font(scale.glyph.font(weight: .bold))
                .foregroundStyle(theme.color("add"))
        case .failed:
            Image(systemName: "xmark")
                .font(scale.glyph.font(weight: .bold))
                .foregroundStyle(theme.color("del"))
        case .cancelled:
            Image(systemName: "stop.fill")
                .font(scale.glyph.font(weight: .bold))
                .foregroundStyle(theme.color("fg-faint"))
        case .other(let status):
            Text(status)
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-faint"))
        }
    }
}

extension ACPContextCompaction {
    var label: String {
        switch status {
        case .inProgress: "Compacting context"
        case .completed: "Context compacted"
        case .failed: "Context compaction failed"
        case .cancelled: "Context compaction cancelled"
        case .other: "Context compaction"
        }
    }

    var details: String? {
        let prefix = trigger.map { "\($0) · " } ?? ""
        let values: String?
        switch (tokensBefore, tokensAfter, durationMs) {
        case let (before?, after?, duration?):
            values = "\(before) → \(after) tokens · \(duration) ms"
        case let (before?, after?, nil):
            values = "\(before) → \(after) tokens"
        case let (before?, nil, duration?):
            values = "\(before) tokens · \(duration) ms"
        case let (nil, after?, duration?):
            values = "\(after) tokens · \(duration) ms"
        case let (before?, nil, nil):
            values = "\(before) tokens"
        case let (nil, after?, nil):
            values = "\(after) tokens"
        case let (nil, nil, duration?):
            values = "\(duration) ms"
        case (nil, nil, nil):
            values = nil
        }
        return values.map { prefix + $0 } ?? (trigger == nil ? nil : String(prefix.dropLast(3)))
    }
}
