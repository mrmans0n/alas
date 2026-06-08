import SwiftUI

struct ACPNewChatEmptyStateView: View {
    let agentDisplayName: String
    /// Extra bottom padding when this view is hosted without an in-flow
    /// composer.
    let bottomInset: CGFloat
    let onStarterPrompt: (ACPStarterPrompt) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 14) {
            mark
            VStack(spacing: 5) {
                Text("What should we work on?")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                Text("Start with a task, a file, or a rough idea.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.color("fg-dim"))
            }
            starterChips
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, bottomInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New \(agentDisplayName) chat")
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

    private var starterChips: some View {
        ViewThatFits(in: .horizontal) {
            starterChipRow
            starterChipColumn
        }
    }

    private var starterChipRow: some View {
        HStack(spacing: 8) {
            ForEach(ACPStarterPrompt.allCases) { prompt in
                starterChip(prompt)
            }
        }
    }

    private var starterChipColumn: some View {
        VStack(spacing: 8) {
            ForEach(ACPStarterPrompt.allCases) { prompt in
                starterChip(prompt)
            }
        }
    }

    private func starterChip(_ prompt: ACPStarterPrompt) -> some View {
        Button {
            onStarterPrompt(prompt)
        } label: {
            Text(prompt.label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(theme.color("bg-2").opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(theme.color("line"), lineWidth: 0.6)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(prompt.promptText)
    }
}

enum ACPNewChatEmptyStateArtwork {
    static let systemImageName = "sparkles"
    static let fontSize: CGFloat = 28
    static let frameSize: CGFloat = 40
}
