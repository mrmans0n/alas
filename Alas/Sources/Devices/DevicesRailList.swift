import AlasCore
import SwiftUI

/// The Devices rail's stack: every running device one under the other, each
/// expanded to its screen, collapsed to its header, or a one-line placeholder
/// while a center tab shows it. One expanded device fills the rail; two or more
/// split it in two, and the rest scroll. A screen scrolled out of view isn't
/// drawn, so its stream stops.
struct DevicesRailList<Stage: View, Actions: View>: View {
    let entries: [DevicesRail.Entry]
    /// Scrolled to once, then cleared.
    @Binding var scrollRequest: DevicesTarget?
    let onToggleCollapsed: (DevicesTarget) -> Void
    let onOpenInTab: (DevicesTabState.Running) -> Void
    let onBringBack: (DevicesTarget) -> Void
    /// A click on a device's header.
    let onUse: (DevicesTarget) -> Void
    /// The screen's height over its width as shown; nil fills the stage.
    let aspect: (DevicesTabState.Running) -> Double?
    @ViewBuilder let stage: (DevicesTabState.Running) -> Stage
    @ViewBuilder let actions: (DevicesTabState.Running) -> Actions
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    /// Expanded devices scrolled out of view.
    @State private var offscreen: Set<DevicesTarget> = []

    private static var padding: CGFloat { 8 }

    var body: some View {
        GeometryReader { geometry in
            let layout = DevicesRailLayout(visibleHeight: geometry.size.height - Self.padding * 2, entries: entries)
            let width = geometry.size.width - Self.padding * 2
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) { // design-literal: DevicesRailLayout's row gap
                        ForEach(entries) { entry in
                            row(entry, layout: layout, width: width)
                                .id(entry.id)
                        }
                    }
                    .padding(Self.padding)
                }
                // A device an agent just opened may not be listed yet: the request waits for it.
                .onChange(of: scrollRequest, initial: true) { _, _ in scrollToRequest(proxy) }
                .onChange(of: entries.map(\.id)) { _, _ in scrollToRequest(proxy) }
            }
        }
    }

    private func scrollToRequest(_ proxy: ScrollViewProxy) {
        guard let target = scrollRequest, entries.contains(where: { $0.id == target }) else { return }
        withAnimation { proxy.scrollTo(target, anchor: .top) }
        scrollRequest = nil
    }

    @ViewBuilder
    private func row(_ entry: DevicesRail.Entry, layout: DevicesRailLayout, width: CGFloat) -> some View {
        let device = entry.device
        switch entry.placement {
        case .inCenter:
            placeholder(device)
        case .expanded, .collapsed:
            VStack(spacing: 8) { // design-literal: DevicesRailLayout's row gap
                DeviceEntryHeader(
                    row: device.row, collapsed: entry.placement == .collapsed,
                    onToggleCollapsed: { onToggleCollapsed(device.id) },
                    move: .toTab, onMove: { onOpenInTab(device) }
                ) {
                    actions(device)
                }
                .simultaneousGesture(TapGesture().onEnded { onUse(device.id) })
                if entry.placement == .expanded {
                    Group {
                        if offscreen.contains(device.id) {
                            Color.clear
                        } else {
                            stage(device)
                        }
                    }
                    .frame(height: layout.height(width: width, aspect: aspect(device), chrome: Self.chrome(device)))
                    .onScrollVisibilityChange(threshold: 0.01) { shown in
                        if shown { offscreen.remove(device.id) } else { offscreen.insert(device.id) }
                    }
                    // Collapsed or moved to a tab while out of view: it comes back drawn.
                    .onDisappear { offscreen.remove(device.id) }
                }
            }
        }
    }

    private func placeholder(_ device: DevicesTabState.Running) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.color(DeviceStyle.colorToken(device.row.tone)))
                .frame(width: 7, height: 7) // design-literal: status dot size
            Text(device.row.title)
                .font(scale.meta.font(weight: .medium))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
            Text("in a tab")
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-dim"))
            Spacer(minLength: 4)
            AlasButton(title: "Bring back", compact: true) { onBringBack(device.id) }
        }
        .padding(.horizontal, scale.space[2])
        .frame(height: 28) // design-literal: DevicesRailLayout's header row
        .background(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        )
    }

    /// Around a phone screen: the stage's margins, bezel and button gutter. Around a VM: its padding.
    static func chrome(_ device: DevicesTabState.Running) -> DevicesRailLayout.Chrome {
        if case .vm = device.screen { return .init(horizontal: 24, vertical: 24) }
        let margin = Double(DeviceStageMetrics.margin), bezel = Double(DeviceStageMetrics.bezel)
        return .init(
            horizontal: margin * 2 + Double(DeviceStageMetrics.gutterWidth) + bezel * 2,
            vertical: margin * 2 + bezel * 2
        )
    }
}
