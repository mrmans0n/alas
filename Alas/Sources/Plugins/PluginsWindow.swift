#if DEBUG
import AppKit
import SwiftUI

struct PluginsView: View {
    let manager: PluginManager

    var body: some View {
        List {
            Section("Folder") {
                HStack {
                    Text(manager.directory.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([manager.directory]) }
                    Button("Reload") { Task { await manager.reload() } }
                }
            }
            ForEach(manager.plugins) { plugin in
                Section("\(plugin.manifest.name) \(plugin.manifest.version) · \(plugin.id)") {
                    if manager.isApproved(plugin) {
                        ForEach(manager.hosts(for: plugin), id: \.key) { entry in
                            PluginHostRow(host: entry.host) { Task { await manager.restart(entry.key) } }
                        }
                    } else {
                        Text(plugin.manifest.capabilities.isEmpty ? "Requests no capabilities." : "Requests:")
                        ForEach(plugin.manifest.capabilities, id: \.self) { capability in
                            Text("• \(capability.summary)")
                        }
                        Button("Approve and run") { Task { await manager.approve(plugin) } }
                    }
                }
            }
            if !manager.invalid.isEmpty {
                Section("Not loaded") {
                    ForEach(manager.invalid) { entry in
                        Text("\(entry.folder.lastPathComponent): \(entry.reason)")
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct PluginHostRow: View {
    let host: PluginHost
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(host.project.name).bold()
                Text(Self.label(host.state)).foregroundStyle(.secondary)
                Spacer()
                Button("Restart", action: restart)
            }
            ForEach(Array(host.log.suffix(5).enumerated()), id: \.offset) { _, entry in
                Text("[\(entry.level)] \(entry.message)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            DisclosureGroup("Messages (\(host.trace.count))") {
                ForEach(Array(host.trace.suffix(20).enumerated()), id: \.offset) { _, entry in
                    Text("\(entry.direction == .toPlugin ? "→" : "←") \(entry.text)")
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    static func label(_ state: PluginHostState) -> String {
        switch state {
        case .loaded: "loaded"
        case .activating: "activating"
        case .active: "active"
        case .deactivating: "deactivating"
        case .stopped: "stopped"
        case .failed(let reason): "Plugin stopped: \(reason)"
        }
    }
}

/// Owns the plugin manager for Phase 2: plugins start the first time this
/// window opens and keep running after it closes, until the app quits.
@MainActor
final class PluginsWindowController: NSObject, NSWindowDelegate {
    static let shared = PluginsWindowController()
    private var window: NSWindow?
    private var manager: PluginManager?

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let manager = self.manager ?? makeManager(state: state)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        win.title = "Plugins"
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: PluginsView(manager: manager))
        win.center()
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }

    private func makeManager(state: AppState) -> PluginManager {
        let manager = PluginManager(
            projects: { [weak state] in state?.projects ?? [] },
            actions: { [weak state] project in
                state?.pluginHostActions(for: project)
                    ?? PluginHostActions(snapshot: { PluginWorkspaceSnapshot(worktrees: []) }, switchWorktree: { _ in false })
            })
        self.manager = manager
        Task { await manager.reload() }
        return manager
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === window {
            window = nil
        }
    }
}
#endif
