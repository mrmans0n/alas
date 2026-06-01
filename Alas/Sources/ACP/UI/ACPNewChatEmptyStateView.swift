import SwiftUI

struct ACPNewChatEmptyStateView: View {
    let agentDisplayName: String
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
        .padding(.bottom, 210)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New \(agentDisplayName) chat")
    }

    private var mark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.color("accent-soft"),
                            theme.color("bg-2").opacity(0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.color("accent").opacity(0.28), lineWidth: 0.75)
            Image(systemName: "sparkle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
        }
        .frame(width: 40, height: 40)
    }

    private var starterChips: some View {
        HStack(spacing: 8) {
            ForEach(ACPStarterPrompt.allCases) { prompt in
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
    }
}
