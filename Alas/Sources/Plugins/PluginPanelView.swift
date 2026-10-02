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
            plugin.manifest.panels.map {
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
    /// The host told the panel is shown, so the same one is told when it goes.
    @State private var reported: PluginHost?

    var body: some View {
        let manager = state.pluginManager
        let host = manager?.host(pluginID: item.ref.pluginID, projectID: projectID)
        let panel = item.ref.panelID
        // Hosts exist only for approved, enabled plugins.
        let content = PluginTabContent.resolve(
            pluginsOn: manager != nil, found: host != nil, approved: true, enabled: true,
            hostState: host?.state, hasContent: host?.panelViews[panel] != nil)
        Group {
            switch content {
            case .content:
                if let host { PluginViewTabView(host: host, panel: panel) }
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
        .onAppear {
            reported = host
            if let host { Task { await host.setPanelVisible(panel, true) } }
        }
        .onDisappear {
            if let reported { Task { await reported.setPanelVisible(panel, false) } }
            reported = nil
        }
        // A reload or update replaces the host while the panel stays on screen: the report moves to the new one.
        .onChange(of: host.map(ObjectIdentifier.init)) { _, _ in
            if let reported, reported !== host { Task { await reported.setPanelVisible(panel, false) } }
            reported = host
            if let host { Task { await host.setPanelVisible(panel, true) } }
        }
    }
}
