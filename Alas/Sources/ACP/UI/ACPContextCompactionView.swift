import SwiftUI

/// A non-interactive transcript marker for a context compaction lifecycle.
struct ACPContextCompactionView: View {
    let compaction: ACPContextCompaction
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.color("accent"))
                    .frame(width: 18, height: 18)
                    .background(theme.color("bg-0").opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                Text(compaction.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(theme.color("fg-faint"))
                Spacer(minLength: 6)
                status
            }

            if let details = compaction.details { Text(details)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))
            }
            if let error = compaction.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("del"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(theme.color("bg-1").opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch compaction.status {
        case .inProgress:
            Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("add"))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("del"))
        case .cancelled:
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.color("fg-faint"))
        case .other(let status):
            Text(status)
                .font(.system(size: 10))
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
