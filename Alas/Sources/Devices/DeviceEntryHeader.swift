import AlasCore
import SwiftUI

/// Colors and symbols the Devices rail, its center tabs and + Add share.
enum DeviceStyle {
    static func colorToken(_ tone: DevicesTabState.Tone) -> String {
        switch tone {
        case .live: "add"
        case .busy: "warn"
        case .idle: "fg-faint"
        }
    }

    static func glyph(_ platform: DevicesPlatform) -> String {
        switch platform {
        case .ios: "iphone"
        case .android: "candybarphone"
        case .vm(.macOS): "macwindow"
        case .vm(.linux): "terminal"
        }
    }
}

/// One device's header in the Devices rail and its center tab: the collapse
/// chevron, the status dot, its name and OS line, then its actions and the
/// move between the rail and a tab.
struct DeviceEntryHeader<Actions: View>: View {
    enum Move {
        case toTab, toRail

        var icon: String {
            switch self {
            case .toTab: "arrow.up.left.and.arrow.down.right"
            case .toRail: "sidebar.right"
            }
        }

        var help: String {
            switch self {
            case .toTab: "Open in a tab"
            case .toRail: "Back to the Devices rail"
            }
        }
    }

    let row: DevicesTabState.Row
    /// Nil hides the chevron, as a center tab does.
    var collapsed: Bool?
    var onToggleCollapsed: () -> Void = {}
    let move: Move
    let onMove: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            if let collapsed {
                Button(action: onToggleCollapsed) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold)) // design-literal: disclosure chevron
                        .foregroundStyle(theme.color("fg-faint"))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show the screen" : "Collapse")
            }
            Circle()
                .fill(theme.color(DeviceStyle.colorToken(row.tone)))
                .frame(width: 7, height: 7) // design-literal: status dot size
            Text(row.title)
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
                // The OS line truncates first.
                .layoutPriority(1)
            Text(row.detail)
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-dim"))
                .lineLimit(1)
            Spacer(minLength: 4)
            actions()
                .layoutPriority(2)
            ToolbarBtn(icon: move.icon, tooltip: move.help, action: onMove)
                .layoutPriority(2)
        }
        .frame(height: 28) // design-literal: DevicesRailLayout's header row
        .contentShape(Rectangle())
    }
}
