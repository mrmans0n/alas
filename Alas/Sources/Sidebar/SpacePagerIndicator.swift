import SwiftUI

struct SpacePagerItemStyle: Equatable {
    let opacity: Double
    let isGrayscale: Bool

    static func style(isActive: Bool) -> SpacePagerItemStyle {
        SpacePagerItemStyle(opacity: isActive ? 1.0 : 0.55, isGrayscale: !isActive)
    }
}

struct SpacePagerIndicator: View {
    let spaces: [SpaceConfig]
    let activeSpaceId: String
    let titleVisible: Bool
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 6) {
            if titleVisible, let active = spaces.first(where: { $0.id == activeSpaceId }) {
                Text(active.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                ForEach(spaces) { space in
                    let style = SpacePagerItemStyle.style(isActive: space.id == activeSpaceId)
                    Text(space.emoji)
                        .font(.system(size: 15))
                        .opacity(style.opacity)
                        .saturation(style.isGrayscale ? 0 : 1)
                        .help(space.name)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.18), value: titleVisible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spaces")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let index = spaces.firstIndex(where: { $0.id == activeSpaceId }) else { return "" }
        return "\(spaces[index].name), \(index + 1) of \(spaces.count)"
    }
}
