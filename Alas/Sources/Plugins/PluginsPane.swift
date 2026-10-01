import AppKit
import SwiftUI

extension PluginHostState {
    var displayText: String {
        switch self {
        case .loaded: "Loaded"
        case .activating: "Starting"
        case .active: "Active"
        case .deactivating: "Stopping"
        case .stopped: "Stopped"
        case .failed(let reason): "Stopped: \(reason)"
        }
    }
}

struct PluginsPane: View {
    let state: AppState
    @Environment(\.theme) var theme
    @State private var approving: PluginManager.Plugin?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Plugins").font(.system(size: 18, weight: .semibold))
                Text("WebAssembly plugins run sandboxed, with only the capabilities you approve.")
                    .font(.system(size: 12.5)).foregroundColor(theme.color("fg-dim"))
                    .padding(.bottom, 12)
                if let manager = state.pluginManager {
                    content(manager)
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
        }
        .sheet(item: $approving) { plugin in
            PluginApprovalSheet(plugin: plugin) { approved in
                approving = nil
                if approved, let manager = state.pluginManager {
                    Task { await manager.approve(plugin) }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ manager: PluginManager) -> some View {
        HStack {
            AlasButton(title: "Reveal Plugins Folder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([manager.directory])
            }
            AlasButton(title: "Rescan", icon: "arrow.clockwise") { Task { await manager.reload() } }
        }
        .padding(.bottom, 12)
        if manager.plugins.isEmpty {
            SettingsRow(name: "No plugins installed.", desc: nil) { }
        }
        ForEach(manager.plugins) { plugin in
            SettingsGroup(title: "\(plugin.manifest.name) \(plugin.manifest.version)") {
                SettingsRow(name: plugin.id, desc: Self.status(manager, plugin)) {
                    if manager.isApproved(plugin) {
                        AlasToggle(on: Binding(
                            get: { manager.isEnabled(plugin) },
                            set: { enabled in Task { await manager.setEnabled(plugin, enabled) } }))
                        AlasButton(title: "Revoke Approval", style: .normal) { Task { await manager.revoke(plugin) } }
                    } else {
                        AlasButton(title: "Approve…", style: .normal) { approving = plugin }
                    }
                }
                ForEach(manager.hosts(for: plugin), id: \.key) { entry in
                    SettingsRow(name: "\(entry.host.project.name) host", desc: entry.host.state.displayText) {
                        AlasButton(title: "Restart", style: .subtle) { Task { await manager.restart(entry.key) } }
                    }
                    if !entry.host.log.isEmpty {
                        HostLogDisclosure(log: entry.host.log)
                    }
                }
            }
        }
        if !manager.invalid.isEmpty {
            SettingsGroup(title: "Not loaded") {
                ForEach(manager.invalid) { entry in
                    SettingsRow(name: entry.folder.lastPathComponent, desc: entry.reason, selectable: true) { }
                }
            }
        }
    }

    private static func status(_ manager: PluginManager, _ plugin: PluginManager.Plugin) -> String {
        if !manager.isApproved(plugin) { return "Not approved" }
        if !manager.isEnabled(plugin) { return "Disabled" }
        return "Enabled"
    }
}

/// Host log collapsed by default: PluginHost retains up to 200 entries of up
/// to 2,000 characters each, so rendering it inline would flood the pane.
private struct HostLogDisclosure: View {
    let log: [PluginLogEntry]
    @State private var isExpanded = false
    @Environment(\.theme) var theme

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(log.suffix(20).enumerated()), id: \.offset) { _, entry in
                    Text("[\(entry.level)] \(entry.message)")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            .padding(.vertical, 6)
        } label: {
            Text("Log (\(log.count))")
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-dim"))
        }
        .padding(.leading, 12)
        .padding(.bottom, 10)
    }
}

private struct PluginApprovalSheet: View {
    let plugin: PluginManager.Plugin
    let finish: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve \(plugin.manifest.name)?").font(.headline)
            Text("\(plugin.id) · version \(plugin.manifest.version)").font(.caption).foregroundStyle(.secondary)
            if plugin.manifest.capabilities.isEmpty {
                Text("It requests no capabilities.")
            } else {
                Text("It will be able to:")
                ForEach(plugin.manifest.capabilities, id: \.self) { Text("• \($0.summary)") }
            }
            Text("Changing the plugin's files requires approving it again.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button("Approve") { finish(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
