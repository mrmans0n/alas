import SwiftUI

struct DiffInlineAnnotationCard: View {
    let annotation: DiffInlineAnnotation

    @State private var showDetails = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            accentBar
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(accentColor.opacity(0.4), lineWidth: 0.75)
        )
        .padding(.horizontal, 1)
        .padding(.vertical, 2)
    }

    private var accentBar: some View {
        accentColor
            .frame(width: 3)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 6,
                    bottomLeadingRadius: 6,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
            )
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: levelIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)
                Text(annotation.checkName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
            }
            Text(annotation.message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
                .fixedSize(horizontal: false, vertical: true)

            if let rawDetails = annotation.rawDetails, !rawDetails.isEmpty {
                Button {
                    showDetails.toggle()
                } label: {
                    Text(showDetails ? "Hide details" : "Show details")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.color("accent"))
                }
                .buttonStyle(.plain)

                if showDetails {
                    Text(rawDetails)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var cardBackground: Color {
        switch annotation.level {
        case .failure: return theme.color("del").opacity(0.06)
        case .warning: return theme.color("warn").opacity(0.06)
        case .notice:  return theme.color("info").opacity(0.06)
        }
    }

    private var accentColor: Color {
        switch annotation.level {
        case .failure: return theme.color("del")
        case .warning: return theme.color("warn")
        case .notice:  return theme.color("info")
        }
    }

    private var levelIcon: String {
        switch annotation.level {
        case .failure: return "xmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .notice:  return "info.circle"
        }
    }
}
