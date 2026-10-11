import SwiftUI

/// A badge on a row, with the plugin and project whose host would run its command.
struct PluginDecorationItem: Identifiable, Equatable {
    let pluginID: String
    let projectID: String
    let key: PluginDecorationKey
    let index: Int
    let decoration: PluginDecoration
    var id: String { "\(pluginID)/\(index)" }
}

extension PluginViewNode.Tone {
    /// The theme color a tone draws with.
    var colorKey: String {
        switch self {
        case .normal: "fg"
        case .dim: "fg-dim"
        case .accent: "accent"
        case .warn: "warn"
        case .danger: "del"  // the theme has no "danger" key; "del" is its red
        case .success: "add"  // and "add" its green
        }
    }
}

/// A row's plugin badges. One with a command is a button.
struct PluginDecorationBadges: View {
    let items: [PluginDecorationItem]
    let run: (PluginDecorationItem) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ForEach(items) { item in
            let color = theme.color((item.decoration.tone ?? .dim).colorKey)
            let badge = Text(item.decoration.text)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundColor(color)
                .background(Capsule().fill(color.opacity(0.15)))
                .fixedSize()
                .help(item.decoration.tooltip ?? "")
            if item.decoration.command != nil {
                Button { run(item) } label: { badge }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel(item.decoration.tooltip ?? item.decoration.text)
            } else {
                badge.accessibilityLabel(item.decoration.tooltip ?? item.decoration.text)
            }
        }
    }
}
