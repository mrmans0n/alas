import SwiftUI

enum ACPFirstRunConnectingViewCopy {
    static let title = "Connecting..."

    static func subtitle(agentDisplayName: String) -> String {
        "Preparing a new \(agentDisplayName) chat."
    }
}

struct ACPFirstRunConnectingView: View {
    let agentDisplayName: String
    let phase: ACPFirstRunConnectingPhase
    /// Bottom padding that lifts the centred content clear of the floating
    /// composer. Responsive to pane height so the composer never overlaps the
    /// phase chips on short panes (see `raisedHeroBottomPadding`).
    let bottomInset: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            mark
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    Spinner().frame(width: 14, height: 14)
                    Text(ACPFirstRunConnectingViewCopy.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.color("fg"))
                }
                Text(ACPFirstRunConnectingViewCopy.subtitle(agentDisplayName: agentDisplayName))
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            phaseChips
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, bottomInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connecting new \(agentDisplayName) chat")
    }

    private var mark: some View {
        Image(systemName: ACPNewChatEmptyStateArtwork.systemImageName)
            .font(.system(size: ACPNewChatEmptyStateArtwork.fontSize, weight: .semibold))
            .foregroundStyle(theme.color("accent"))
            .frame(
                width: ACPNewChatEmptyStateArtwork.frameSize,
                height: ACPNewChatEmptyStateArtwork.frameSize
            )
    }

    private var phaseChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(ACPFirstRunConnectingPhase.allCases, id: \.self) { item in
                    phaseChip(item)
                }
            }
            VStack(spacing: 8) {
                ForEach(ACPFirstRunConnectingPhase.allCases, id: \.self) { item in
                    phaseChip(item)
                }
            }
        }
    }

    private func phaseChip(_ item: ACPFirstRunConnectingPhase) -> some View {
        let active = item == phase
        return Text(item.label)
            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? theme.color("fg") : theme.color("fg-muted"))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(theme.color(active ? "bg-2" : "bg-1").opacity(active ? 0.72 : 0.48))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(active ? theme.color("accent-soft") : theme.color("line"), lineWidth: 0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
