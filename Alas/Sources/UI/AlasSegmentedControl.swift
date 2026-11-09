import SwiftUI

enum AlasSegmentedIcon: Equatable {
    case system(String)
    case gg(GGStackIconVariant)
}

struct AlasSegmentedOption<ID: Hashable> {
    let id: ID
    let label: String
    let icon: AlasSegmentedIcon?
    let isEnabled: Bool
    let disabledHelp: String?

    init(
        id: ID,
        label: String,
        icon: String? = nil,
        isEnabled: Bool = true,
        disabledHelp: String? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = icon.map(AlasSegmentedIcon.system)
        self.isEnabled = isEnabled
        self.disabledHelp = disabledHelp
    }

    init(
        id: ID,
        label: String,
        segmentedIcon: AlasSegmentedIcon?,
        isEnabled: Bool = true,
        disabledHelp: String? = nil
    ) {
        self.id = id
        self.label = label
        self.icon = segmentedIcon
        self.isEnabled = isEnabled
        self.disabledHelp = disabledHelp
    }
}

struct AlasSegmentedControl<ID: Hashable>: View {
    let selection: ID
    let options: [AlasSegmentedOption<ID>]
    let onSelect: (ID) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                segment(option)
            }
        }
        .padding(scale.space[0])
        .background(theme.color("seg-container-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
    }

    private func segment(_ option: AlasSegmentedOption<ID>) -> some View {
        let isSelected = selection == option.id

        return Button {
            onSelect(option.id)
        } label: {
            HStack(spacing: 5) {
                if let icon = option.icon {
                    let iconColor = isSelected ? theme.color("fg") : theme.color("fg-muted")
                    switch icon {
                    case .system(let name):
                        Icon(name: name, size: 11, color: iconColor)
                    case .gg(let variant):
                        GGStackIcon(variant: variant, size: 11, color: iconColor)
                            .accessibilityHidden(true)
                    }
                }
                Text(option.label)
                    .font(scale.meta.font(weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.color("fg") : theme.color("fg-muted"))
            }
            .padding(.horizontal, scale.space[2])
            .frame(height: 22)
            .background {
                if isSelected {
                    ZStack {
                        RoundedRectangle(cornerRadius: scale.radius.small).fill(theme.color("bg-3"))
                        RoundedRectangle(cornerRadius: scale.radius.small)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
            .shadow(color: isSelected ? Color.black.opacity(0.25) : .clear, radius: 1, x: 0, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .focusable(option.isEnabled)
        .focusEffectDisabled()
        .disabled(!option.isEnabled)
        .opacity(option.isEnabled ? 1 : 0.4)
        .modifier(AlasSegmentHelpModifier(
            text: option.isEnabled ? nil : option.disabledHelp
        ))
    }
}

private struct AlasSegmentHelpModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
