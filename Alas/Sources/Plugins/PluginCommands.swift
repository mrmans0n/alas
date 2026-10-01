import SwiftUI

/// Where Alas shows a plugin command. A manifest may name slots this Alas does not know; those are skipped.
enum PluginCommandSlot: String, Sendable, Hashable {
    case palette
    case menubar
    case toolbar
    case worktreeMenu = "worktree.menu"
    case repoMenu = "repo.menu"
}

/// A manifest command. Alas draws it without asking the plugin, and sends `command/run` when it is chosen.
struct PluginCommandContribution: Equatable, Sendable {
    let id: String
    let title: String
    /// An SF Symbol name.
    var icon: String?
    let slots: [PluginCommandSlot]
}

/// `command/run`'s `target`: the project, or one of its worktrees.
struct PluginCommandTarget: Codable, Equatable, Sendable {
    let kind: String
    var worktree: String?

    static let project = PluginCommandTarget(kind: "project")
    static func worktree(_ id: String) -> PluginCommandTarget { PluginCommandTarget(kind: "worktree", worktree: id) }
}

struct PluginCommandRunParams: Codable, Sendable {
    let command: String
    let target: PluginCommandTarget
}

/// One command as shown in a slot, for the project whose host would run it.
struct PluginCommandItem: Identifiable, Equatable, Sendable {
    let pluginID: String
    let projectID: String
    let command: PluginCommandContribution
    var id: String { "\(pluginID)/\(command.id)" }
}

enum PluginCommandRouting {
    /// Commands placed in `slot` by the plugins whose host for `projectID` is active, in plugin order.
    static func items(
        in slot: PluginCommandSlot,
        projectID: String,
        plugins: [(manifest: PluginManifest, isActive: Bool)]
    ) -> [PluginCommandItem] {
        plugins.filter(\.isActive).flatMap { plugin in
            plugin.manifest.commands.filter { $0.slots.contains(slot) }.map {
                PluginCommandItem(pluginID: plugin.manifest.id, projectID: projectID, command: $0)
            }
        }
    }

    /// The toolbar and worktree menu act on a worktree, so they have no target without one.
    static func target(for slot: PluginCommandSlot, worktreeID: String?) -> PluginCommandTarget? {
        switch slot {
        case .palette, .menubar, .repoMenu: .project
        case .toolbar, .worktreeMenu: worktreeID.map(PluginCommandTarget.worktree)
        }
    }
}

/// One flat button per command. Menus list these directly: data-driven submenus render empty in context menus on macOS.
struct PluginCommandButtons: View {
    let items: [PluginCommandItem]
    let run: (PluginCommandItem) -> Void

    var body: some View {
        ForEach(items) { item in
            Button { run(item) } label: {
                if let icon = item.command.icon {
                    Label(item.command.title, systemImage: icon)
                } else {
                    Text(item.command.title)
                }
            }
        }
    }
}
