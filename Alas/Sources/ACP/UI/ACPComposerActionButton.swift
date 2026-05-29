import SwiftUI

/// Single state-driven button that replaces the composer's separate Send
/// and Stop affordances. Pure render of a `ComposerAction` — knows nothing
/// about `ACPSession` or the runner. The shell wires `onPrimary` / `onMenu`
/// to the appropriate `submitWithIntent` / `userCancel` calls.
struct ACPComposerActionButton: View {
    let action: ComposerAction
    let onPrimary: () -> Void
    let onMenu: (ComposerMenuItem) -> Void
    let queueBadgeCount: Int

    @Environment(\.theme) private var theme

    var body: some View {
        switch action {
        case .hidden:
            EmptyView()
        case .send:
            sendCapsule
        case .stop:
            stopCapsule
        case .queue(let menu):
            queueSplitCapsule(menu: menu)
        }
    }

    // MARK: - Send (single capsule, accent-colored)

    private var sendCapsule: some View {
        Button(action: onPrimary) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                Text("Send")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(theme.color("bg-0"))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(theme.color("accent"))
            )
            .overlay(badgeOverlay)
        }
        .buttonStyle(.plain)
        .help("Send (⏎)")
    }

    // MARK: - Stop (single capsule, destructive treatment)

    private var stopCapsule: some View {
        Button(action: onPrimary) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Stop")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(theme.color("del"))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(theme.color("del").opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(theme.color("del").opacity(0.45), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help("Stop the running turn (Esc)")
    }

    // MARK: - Queue (split capsule, primary + chevron menu)

    private func queueSplitCapsule(menu: [ComposerMenuItem]) -> some View {
        HStack(spacing: 1) {
            Button(action: onPrimary) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                    Text("Queue")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(theme.color("fg"))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(theme.color("bg-3"))
                .overlay(badgeOverlay)
            }
            .buttonStyle(.plain)
            .help("Queue (⏎). Hold ⌥ to steer.")

            Menu {
                ForEach(menu, id: \.self) { item in
                    menuButton(for: item)
                    if item == .steer, menu.contains(.stop) {
                        Divider()
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(theme.color("bg-3"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.color("line"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private func menuButton(for item: ComposerMenuItem) -> some View {
        switch item {
        case .steer:
            Button {
                onMenu(.steer)
            } label: {
                Label("Steer running turn (⌥⏎)", systemImage: "arrow.turn.up.right")
            }
        case .stop:
            Button(role: .destructive) {
                onMenu(.stop)
            } label: {
                Label("Stop running turn (Esc)", systemImage: "stop.fill")
            }
        }
    }

    // MARK: - Queue count badge (rendered on Send & Queue primary halves)

    @ViewBuilder
    private var badgeOverlay: some View {
        if queueBadgeCount > 0 {
            Text("\(queueBadgeCount)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.color("bg-0"))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 14)
                .background(Capsule().fill(theme.color("warn")))
                .overlay(Capsule().strokeBorder(theme.color("bg-0"), lineWidth: 1))
                .offset(x: 6, y: -6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
    }
}
