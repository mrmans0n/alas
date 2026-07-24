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

    @FocusState private var focusedOption: ID?
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(theme.color("seg-container-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func segment(_ option: AlasSegmentedOption<ID>) -> some View {
        let isSelected = selection == option.id
        let isFocused = focusedOption == option.id

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
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.color("fg") : theme.color("fg-muted"))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background {
                if isSelected {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(theme.color("bg-3"))
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.04), lineWidth: 1)
                            .blendMode(.plusLighter)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.color("accent"), lineWidth: isFocused ? 1 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(option.isEnabled)
        .focused($focusedOption, equals: option.id)
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
