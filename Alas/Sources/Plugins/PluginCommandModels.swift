import Foundation

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
