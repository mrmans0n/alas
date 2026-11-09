#if DEBUG
import Foundation

/// Design captures of the plugin screens: starts the plugin manager over the
/// demo plugins `make-demo-profile.sh` seeds into the profile's Plugins folder,
/// with an offline catalog, and opens their tabs and panels through the same
/// entry points commands use. Debug builds only; driven by `DesignCaptureBridge`.
@MainActor
enum DesignCapturePlugins {
    nonisolated static let releaseNotes = "io.example.demo-release-notes"
    nonisolated static let standup = "io.example.demo-standup"
    private static let hello = "io.nlopez.hello-workspace"
    private static let digest = "io.example.demo-nightly-digest"

    /// Starts plugins once: approves the demo plugins, leaves the sample disabled, and waits until the
    /// two that draw something are running in the demo project.
    static func start(state: AppState) async {
        let deadline = Date().addingTimeInterval(30)
        while state.projects.isEmpty {
            guard Date() < deadline else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if state.pluginManager == nil {
            state.config.pluginsEnabled = true
            let manager = PluginManager(
                projects: { [weak state] in state?.projects ?? [] },
                actions: { [weak state] project in state?.pluginHostActions(for: project) ?? .inert },
                catalog: PluginCatalog(fetch: { _ in try await MainActor.run { try offlineIndex() } }))
            state.pluginManager = manager
            await manager.reload()
            for plugin in manager.plugins where plugin.id != hello {
                await manager.approve(plugin)
            }
            if let plugin = manager.plugins.first(where: { $0.id == hello }) {
                await manager.approve(plugin)
                await manager.setEnabled(plugin, false)
            }
            await manager.catalog.refresh()
        }
        guard let manager = state.pluginManager, let projectID = state.projects.first?.id else { return }
        let limit = Date().addingTimeInterval(20)
        while Date() < limit {
            let running = [releaseNotes, standup].allSatisfy { manager.host(pluginID: $0, projectID: projectID)?.state == .active }
            if running { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Lets the plugins' first renders, badges and decorations arrive.
        try? await Task.sleep(for: .seconds(1))
    }

    /// `plugin-tab` (Release Notes web tab), `plugin-view-tab` (Standup view tab), `plugin-panel` (Standup view
    /// panel in the right pane) or `plugin-web-panel` (Release Notes changelog web panel).
    static func open(_ target: String, state: AppState) async {
        await start(state: state)
        guard let worktree = state.selectedWorktreeId else { return }
        switch target {
        case "plugin-tab":
            state.openPluginTab(PluginTabState(pluginID: releaseNotes, contributionID: "notes", title: "Release notes"), worktreeID: worktree)
        case "plugin-view-tab":
            state.openPluginTab(PluginTabState(pluginID: standup, contributionID: "board", title: "Standup"), worktreeID: worktree)
        case "plugin-panel":
            state.openPluginPanel(PluginPanelRef(pluginID: standup, panelID: "today"), worktreeID: worktree)
        case "plugin-web-panel":
            state.openPluginPanel(PluginPanelRef(pluginID: releaseNotes, panelID: "changelog"), worktreeID: worktree)
        default:
            break
        }
    }

    /// A catalog that never touches the network: it offers Release Notes 1.3.0 as an update to the installed
    /// 1.2.0, and one plugin to install. The hashes of installed files must match for the update to show.
    private static func offlineIndex() throws -> Data {
        let base = "https://plugins.example.invalid"
        func version(_ number: String, hash: String, capabilities: [String]) -> [String: Any] {
            [
                "version": number, "api": 15, "capabilities": capabilities,
                "manifest": "\(base)/\(number)/plugin.json", "entry": "\(base)/\(number)/plugin.js", "hash": hash,
            ]
        }
        let installedHash = PluginManager.discover(in: PluginManager.defaultDirectory).plugins
            .first { $0.id == releaseNotes }?.hash ?? ""
        let index: [String: Any] = [
            "format": 1,
            "plugins": [
                [
                    "id": releaseNotes, "name": "Release Notes", "summary": "Shows what shipped in each release.",
                    "versions": [
                        version("1.2.0", hash: installedHash, capabilities: ["workspace.read"]),
                        version("1.3.0", hash: String(repeating: "0", count: 64), capabilities: ["workspace.read", "notify"]),
                    ],
                ],
                [
                    "id": "io.example.demo-pr-inbox", "name": "PR Inbox", "summary": "Pull requests waiting on you, per project.",
                    "versions": [version("0.9.0", hash: String(repeating: "1", count: 64), capabilities: ["workspace.read"])],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: index)
    }
}
#endif
