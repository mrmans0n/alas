import SwiftUI

/// Where Alas shows a plugin command. A manifest may name slots this Alas does not know; those are skipped.
enum PluginCommandSlot: String, Sendable, Hashable {
    case palette
    case menubar
    case toolbar
    case worktreeMenu = "worktree.menu"
    case repoMenu = "repo.menu"
    // API 6.
    case changesToolbar = "changes.toolbar"
    case changesFileMenu = "changes.file.menu"
    case changesCommitMenu = "changes.commit.menu"
    case runMenu = "run.menu"
    case runReport = "run.report"
    case sessionMenu = "session.menu"
    // API 7.
    case messageMenu = "message.menu"

    /// The plugin API that introduced the slot; an older manifest that names it has it skipped, as an older Alas would.
    var api: Int {
        switch self {
        case .palette, .menubar, .toolbar, .worktreeMenu, .repoMenu: 5
        case .messageMenu: 7
        default: 6
        }
    }
}

/// A manifest command. Alas draws it without asking the plugin, and sends `command/run` when it is chosen.
struct PluginCommandContribution: Equatable, Sendable {
    let id: String
    let title: String
    /// An SF Symbol name.
    var icon: String?
    let slots: [PluginCommandSlot]
    /// API 8: a tab of the same manifest Alas opens before it runs the command.
    var opens: String? = nil
}

/// `command/run`'s `target`: what the user acted on. `kind` says which of the other fields are set.
struct PluginCommandTarget: Codable, Equatable, Sendable {
    let kind: String
    var worktree: String?
    var path: String?
    var sha: String?
    var script: String?
    var run: String?
    var session: String?
    /// The message's Markdown, for `message.menu`.
    var text: String?

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

    /// Message text beyond this is cut, so `command/run` always fits in a message.
    static let maxMessageTextBytes = 32 * 1024

    /// `detail` is what the slot's row names besides the worktree: a file path, commit sha, run script key,
    /// run id or session id. `text` is the message a `message.menu` command acts on. A slot has no target without
    /// the fields it needs.
    static func target(
        for slot: PluginCommandSlot, worktreeID: String?, detail: String? = nil, text: String? = nil
    ) -> PluginCommandTarget? {
        func inWorktree(_ make: (String, String) -> PluginCommandTarget) -> PluginCommandTarget? {
            guard let worktreeID, let detail else { return nil }
            return make(worktreeID, detail)
        }
        return switch slot {
        case .palette, .menubar, .repoMenu: .project
        case .toolbar, .worktreeMenu, .changesToolbar: worktreeID.map(PluginCommandTarget.worktree)
        case .sessionMenu: detail.map { PluginCommandTarget(kind: "session", session: $0) }
        case .messageMenu:
            detail.flatMap { session in
                text.map {
                    PluginCommandTarget(
                        kind: "message", session: session,
                        text: PluginLastMessageText.bounded($0, maxBytes: maxMessageTextBytes))
                }
            }
        case .changesFileMenu: inWorktree { PluginCommandTarget(kind: "file", worktree: $0, path: $1) }
        case .changesCommitMenu: inWorktree { PluginCommandTarget(kind: "commit", worktree: $0, sha: $1) }
        case .runMenu: inWorktree { PluginCommandTarget(kind: "run", worktree: $0, script: $1) }
        case .runReport: inWorktree { PluginCommandTarget(kind: "runReport", worktree: $0, run: $1) }
        }
    }

    /// A clicked badge acts on its row, like that row's menu.
    static func target(for decoration: PluginDecorationKey) -> PluginCommandTarget? {
        target(for: decoration.slot.commandSlot, worktreeID: decoration.worktree ?? decoration.target, detail: decoration.target)
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

/// One plugin slash prompt as offered in the agent composer.
struct PluginPromptItem: Equatable, Sendable {
    let pluginID: String
    let prompt: PluginPromptContribution

    var suggestion: ACPPromptSuggestion {
        ACPPromptSuggestion(command: "/\(prompt.name)", description: prompt.description)
    }

    /// Prompts of the active plugins, in plugin order. A name already taken, by Alas's own commands or an earlier
    /// plugin, is skipped, so a typed command always reaches one plugin.
    static func items(_ plugins: [(manifest: PluginManifest, isActive: Bool)]) -> [PluginPromptItem] {
        var taken = Set([ACPAlasSlashCommand.btwSuggestion.command])
        return plugins.filter(\.isActive).flatMap { plugin in
            plugin.manifest.prompts.map { PluginPromptItem(pluginID: plugin.manifest.id, prompt: $0) }
        }.filter { taken.insert($0.suggestion.command).inserted }
    }

    /// The prompt a submitted draft starts with, and what follows it.
    static func match(_ text: String, in items: [PluginPromptItem]) -> (item: PluginPromptItem, args: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (suggestion, rest) = ACPSlashCommand.match(in: trimmed, suggestions: items.map(\.suggestion)),
              let item = items.first(where: { $0.suggestion == suggestion })
        else { return nil }
        return (item, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
