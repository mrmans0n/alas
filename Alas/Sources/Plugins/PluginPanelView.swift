import SwiftUI

/// One plugin panel. Hosts are per project, so the project comes from where it is shown.
struct PluginPanelRef: Hashable, Sendable {
    let pluginID: String
    let panelID: String
}

/// A plugin panel's button in the right pane's rail.
struct PluginPanelItem: Equatable, Identifiable {
    let ref: PluginPanelRef
    let title: String
    let icon: String
    var id: PluginPanelRef { ref }

    /// Panels of plugins with a host in the project, in plugin order. A failed host keeps its
    /// panels, so the panel can say it stopped and offer a restart.
    static func items(_ plugins: [(manifest: PluginManifest, hasHost: Bool)]) -> [PluginPanelItem] {
        plugins.filter(\.hasHost).flatMap { plugin in
            plugin.manifest.panels.filter { $0.location == .right }.map {
                PluginPanelItem(
                    ref: PluginPanelRef(pluginID: plugin.manifest.id, panelID: $0.id), title: $0.title, icon: $0.icon)
            }
        }
    }

    /// The selected panel while it is still offered; nil means the pane shows its built-in tab.
    static func selected(_ ref: PluginPanelRef?, in items: [PluginPanelItem]) -> PluginPanelItem? {
        items.first { $0.ref == ref }
    }
}

/// A plugin panel's body in the right pane.
struct PluginPanelView: View {
    let state: AppState
    let projectID: String
    let item: PluginPanelItem
    @Environment(\.theme) var theme

    var body: some View {
        let manager = state.pluginManager
        let host = manager?.host(pluginID: item.ref.pluginID, projectID: projectID)
        let panel = item.ref.panelID
        let kind = manager?.plugin(id: item.ref.pluginID)?.manifest.panels.first { $0.id == panel }?.kind ?? .view
        // A web panel's page is its own content; it posts "ready" when it loads.
        let hasContent: Bool = switch kind {
        case .view: host?.panelViews[panel] != nil
        case .canvas: host?.frames[.panel(panel)] != nil
        case .web: true
        }
        // Hosts exist only for approved, enabled plugins.
        let content = PluginTabContent.resolve(
            pluginsOn: manager != nil, found: host != nil, approved: true, enabled: true,
            hostState: host?.state, hasContent: hasContent)
        Group {
            switch content {
            case .content:
                if let host {
                    switch kind {
                    case .view: PluginViewTabView(host: host, panel: panel)
                    case .canvas: PluginCanvasView(host: host, surface: .panel(panel))
                    case .web: PluginWebTabView(host: host, surface: .panel(panel), script: manager?.plugin(id: item.ref.pluginID)?.web ?? Data())
                    }
                }
            case .stopped(let reason):
                VStack(spacing: 12) {
                    Text("Plugin stopped: \(reason)")
                        .foregroundColor(theme.color("fg-dim"))
                        .multilineTextAlignment(.center)
                    AlasButton(title: "Restart", style: .normal) {
                        guard let manager else { return }
                        Task {
                            await manager.restart(PluginManager.HostKey(pluginID: item.ref.pluginID, projectID: projectID))
                        }
                    }
                }
                .padding(24)
            case .loading, .unavailable:
                Text("Loading…").foregroundColor(theme.color("fg-dim"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ponytail: shown means selected in a mounted pane; window occlusion is not tracked as it is for canvases.
        .pluginPanelsVisible(host.map { [PluginPanelTarget(host: $0, place: PluginPanelPlace(panel: panel))] } ?? [])
    }
}

/// One panel in one place, on the host that renders it.
struct PluginPanelTarget: Equatable, Identifiable {
    let host: PluginHost
    let place: PluginPanelPlace
    var title = ""
    var id: String { "\(host.manifest.id)/\(place.panel)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.host === rhs.host && lhs.place == rhs.place }
}

/// Tells each host its panels are shown while the view is, including when a reload replaces a host or the place
/// changes while the view stays on screen.
private struct PluginPanelVisibility: ViewModifier {
    let targets: [PluginPanelTarget]
    /// The targets told they are shown, so the same ones are told when they go.
    @State private var reported: [PluginPanelTarget] = []

    func body(content: Content) -> some View {
        content
            .onAppear { report(targets) }
            .onDisappear { report([]) }
            .onChange(of: targets) { _, new in report(new) }
    }

    private func report(_ new: [PluginPanelTarget]) {
        for old in reported where !new.contains(old) { old.host.setPanelVisible(old.place, false) }
        for target in new where !reported.contains(target) { target.host.setPanelVisible(target.place, true) }
        reported = new
    }
}

extension View {
    func pluginPanelsVisible(_ targets: [PluginPanelTarget]) -> some View {
        modifier(PluginPanelVisibility(targets: targets))
    }
}

/// A panel drawn inline, in the Changes tab or a run report. Shows nothing until the plugin renders for this place.
struct PluginPanelSectionView: View {
    let target: PluginPanelTarget
    @Environment(\.theme) var theme

    var body: some View {
        if let root = target.host.panelTree(for: target.place) {
            VStack(alignment: .leading, spacing: 6) {
                Text(target.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                PluginViewNodeView(node: root, events: PluginViewEvents(host: target.host, tabIndex: 0, panel: target.place))
                    .id(root.id)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
