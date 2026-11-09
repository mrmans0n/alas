import SwiftUI

enum ACPFirstRunConnectingViewCopy {
    static let title = "Connecting..."

    static func subtitle(agentDisplayName: String) -> String {
        "Preparing a new \(agentDisplayName) chat."
    }
}

struct ACPFirstRunConnectingView: View {
    @Environment(\.designScale) private var scale
    let agentDisplayName: String
    let phase: ACPFirstRunConnectingPhase
    let connectionStartedAt: Date?
    let reconnectAvailable: Bool
    let restartInProgress: Bool
    let onRestart: () -> Void
    /// Extra bottom padding when this view is hosted without an in-flow
    /// composer.
    let bottomInset: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: scale.space[3]) {
            mark
            VStack(spacing: scale.space[2]) {
                HStack(spacing: scale.space[2]) {
                    Spinner().frame(width: 14, height: 14)
                    Text(ACPFirstRunConnectingViewCopy.title)
                        .font(scale.emphasisFont)
                        .foregroundStyle(theme.color("fg"))
                }
                Text(ACPFirstRunConnectingViewCopy.subtitle(agentDisplayName: agentDisplayName))
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-dim"))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            phaseChips
            ACPStalledConnectionButton(
                startedAt: connectionStartedAt,
                reconnectAvailable: reconnectAvailable,
                restartInProgress: restartInProgress,
                onRestart: onRestart
            )
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, scale.space[5])
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, bottomInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connecting new \(agentDisplayName) chat")
    }

    private var mark: some View {
        LovebirdView(pose: .waiting, size: 72)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var phaseChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: scale.space[2]) {
                ForEach(ACPFirstRunConnectingPhase.allCases, id: \.self) { item in
                    phaseChip(item)
                }
            }
            VStack(spacing: scale.space[2]) {
                ForEach(ACPFirstRunConnectingPhase.allCases, id: \.self) { item in
                    phaseChip(item)
                }
            }
        }
    }

    private func phaseChip(_ item: ACPFirstRunConnectingPhase) -> some View {
        let active = item == phase
        return Text(item.label)
            .font(scale.meta.font(weight: active ? .semibold : .medium))
            .foregroundStyle(active ? theme.color("fg") : theme.color("fg-muted"))
            .lineLimit(1)
            .padding(.horizontal, scale.space[2])
            .frame(height: 28)
            .background(theme.color(active ? "bg-2" : "bg-1").opacity(active ? 0.72 : 0.48))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(active ? theme.color("accent-soft") : theme.color("line"), lineWidth: 0.6)
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
    }
}
