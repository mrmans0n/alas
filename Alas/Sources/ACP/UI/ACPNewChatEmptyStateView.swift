import SwiftUI

struct ACPNewChatEmptyStateView: View {
    @Environment(\.designScale) private var scale
    let agentDisplayName: String
    /// Extra bottom padding when this view is hosted without an in-flow
    /// composer.
    let bottomInset: CGFloat
    let onStarterPrompt: (ACPStarterPrompt) -> Void
    var onCreatePreview: (() -> Void)? = nil

    @Environment(\.theme) private var theme
    @State private var confirmsPreview = false

    var body: some View {
        VStack(spacing: scale.space[3]) {
            mark
            VStack(spacing: scale.space[1]) {
                Text("What should we work on?")
                    .font(.system(size: 17, weight: .semibold)) // design-literal: hero title
                    .foregroundStyle(theme.color("fg"))
                Text("Start with a task, a file, or a rough idea.")
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-dim"))
            }
            starterChips
            if onCreatePreview != nil {
                Button("New ACP v2 preview") { confirmsPreview = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, scale.space[5])
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, bottomInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New \(agentDisplayName) chat")
        .confirmationDialog("Start ACP v2 preview?", isPresented: $confirmsPreview) {
            Button("Start preview") { onCreatePreview?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This local preview supports text and permission choices. An ended or interrupted preview cannot resume.")
        }
    }

    private var mark: some View {
        LovebirdView(pose: .hello, size: 72)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }

    private var starterChips: some View {
        ViewThatFits(in: .horizontal) {
            starterChipRow
            starterChipColumn
        }
    }

    private var starterChipRow: some View {
        HStack(spacing: scale.space[2]) {
            ForEach(ACPStarterPrompt.allCases) { prompt in
                starterChip(prompt)
            }
        }
    }

    private var starterChipColumn: some View {
        VStack(spacing: scale.space[2]) {
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
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .padding(.horizontal, scale.space[2])
                .frame(height: 28)
                .background(theme.color("bg-2").opacity(0.58))
                .overlay(
                    RoundedRectangle(cornerRadius: scale.radius.medium)
                        .strokeBorder(theme.color("line"), lineWidth: 0.6)
                )
                .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        }
        .buttonStyle(.plain)
        .help(prompt.promptText)
    }
}
